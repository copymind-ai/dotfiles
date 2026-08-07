#!/usr/bin/env bash
# Monitor for every tmux session: one line each, showing what its Claude window
# is doing, plus a key to jump straight to the one that wants you.
#
#   monitor.sh          open the monitor session (reuses it if up)
#   monitor.sh --run    run the monitor here, in the current pane
#
# Bound to prefix+M in .tmux.conf.
#
# Keys: 1-9 then a-z jump straight to that session. j/k (or the arrow keys) move
# the cursor and enter jumps to it; h and l do nothing, the list being one column.
# r refreshes now, q (or esc) quits.
#
# Every session is listed except the monitor itself. For each one it picks the
# pane to report on: a pane actually running Claude, else one in a window named
# $MONITOR_WINDOW, else the session's active pane.
#
# What each session is doing is read off its screen. Where claude/statusline.sh
# and claude/monitor-hook.sh are installed, they leave what the screen cannot
# show -- context and cost, how many subagents are in flight, and state straight
# from Claude's own events -- in $CLAUDE_MONITOR_DIR, and those are merged in.
# Sessions without them lose the extra columns and nothing else.
#
# The status line also keeps a ledger there of what every session has spent, day
# by day, which outlives the sessions themselves: that is where the day, week,
# month and all-time figures on the total line come from.
#
# Tunables: MONITOR_INTERVAL (seconds, default 2), MONITOR_WINDOW (preferred
# window name, default "claude"), MONITOR_FILTER (regex; only sessions matching
# it are listed, default all), MONITOR_SESSION (default "monitor"),
# CLAUDE_MONITOR_DIR (default ~/.claude/monitor), MONITOR_STALE (seconds an
# exported state stays trusted, default 90).
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

MON=${MONITOR_SESSION:-monitor}
INTERVAL=${MONITOR_INTERVAL:-2}
MONITOR_WINDOW=${MONITOR_WINDOW:-claude}
MONITOR_FILTER=${MONITOR_FILTER:-}
MONITOR_DIR=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}
MONITOR_STALE=${MONITOR_STALE:-90}
# Claude's own session registry, one small JSON file per running session. Read
# only to follow parked jobs; see the parked jobs section.
SESSION_DIR=${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}

# Digits first (natural for the first handful), then letters. 'q' and 'r' are
# left out on purpose -- they are quit and refresh -- and so are hjkl, which move
# the cursor. 29 keys in total; past that, use the cursor.
KEYS="123456789abcdefgimnopstuvwxyz"

# --- terminal control -------------------------------------------------------
# Kept as variables rather than printf escapes so the same strings work in sed
# replacements, where BSD sed would not expand \033.
ESC=$'\033'
T_HOME="${ESC}[H"        # cursor to top-left
T_EL="${ESC}[K"          # erase to end of line
T_ED="${ESC}[J"          # erase to end of screen
T_HIDE="${ESC}[?25l"
T_SHOW="${ESC}[?25h"
T_ALT_ON="${ESC}[?1049h" # alternate screen
T_ALT_OFF="${ESC}[?1049l"

if [ -t 1 ] || [ -n "${MONITOR_FORCE_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RST=; C_BOLD=; C_DIM=; C_REV=; C_RED=; C_GRN=; C_YEL=; C_CYA=
fi

# --- snapshot ---------------------------------------------------------------

# Braille frames Claude spins in the pane title while it works. Only used when
# perl is missing: the perl check in monitor_busy_titles covers the whole braille
# block, so it survives Claude picking frames that are not in this list.
BRAILLE_FRAMES='⠁⠂⠄⠈⠐⠠⡀⢀⠃⠆⠇⠋⠏⠙⠘⠸⠴⠦⠧⠹⠼⣀⣤⣶⣿'

# Claude Code reports its version as the process name ("2.1.222"), so treat a
# bare version and anything containing "claude" as Claude.
is_claude_cmd() {
  case $1 in
    *claude*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Runtimes Claude would surface as if it ever stopped renaming its process. On
# their own these prove nothing -- half the world runs node -- so a pane only
# counts as Claude this way when its title carries one of Claude's glyphs too.
is_claude_host() {
  case $1 in node|bun|deno|npm|npx) return 0 ;; *) return 1 ;; esac
}

# True when a title is one Claude wrote: "<braille frame> summary" while it
# works, "✳ summary" once it stops. Only used to recognise a Claude pane, never
# to decide busy -- monitor_busy_titles does that, and exactly. A title alone is
# never enough: it is set by whatever last wrote to the pane and outlives it, so
# shells sit there wearing Claude's last summary long after Claude has exited.
title_is_claude() {
  [ -n "${1:-}" ] || return 1
  case $1 in '✳'*) return 0 ;; esac
  case $BRAILLE_FRAMES in *"${1:0:1}"*) return 0 ;; esac
  return 1
}

# Everything tmux knows about every pane, in one call.
#
# This used to be three calls per session -- list-windows, capture-pane, then
# display-message for the title -- which cost a fork each and sampled each
# session a few milliseconds apart. One list-panes also reports panes that are
# not the active one, and that fixes a real blind spot: the old format could only
# ever show the active pane's command, so a split window with Claude in its other
# half read as a plain shell.
#
# cursor_x and cursor_y come along for free and are what the classifier leans on
# hardest -- see monitor_classify.
SNAP_SEP=$'\037'   # a control character cannot appear in a session name or title
SNAP_FMT="#{pid}${SNAP_SEP}#{session_name}${SNAP_SEP}#{window_active}${SNAP_SEP}#{pane_id}\
${SNAP_SEP}#{pane_active}${SNAP_SEP}#{cursor_x}${SNAP_SEP}#{cursor_y}\
${SNAP_SEP}#{pane_current_command}${SNAP_SEP}#{window_name}${SNAP_SEP}#{pane_title}"

# The tmux server's pid, which is half of the key the exporters file their state
# under. Pane numbering restarts with a new server, so without it a leftover file
# could be read as some unrelated pane's state.
SERVER_PID=0

P_PANE=()   # per session, same order as SESSIONS: the pane we report on
P_CMD=()
P_CX=()
P_CY=()
P_TITLE=()
P_RANK=()   # how we found it; see the scores below

# Fills SESSIONS and the P_* arrays from one list-panes.
monitor_snapshot() {
  local line spid sess wact pid pact cx cy cmd wname title i n rank
  local raw=()
  SESSIONS=(); P_PANE=(); P_CMD=(); P_CX=(); P_CY=(); P_TITLE=(); P_RANK=()

  while IFS= read -r line; do raw+=("$line"); done \
    < <(tmux list-panes -a -F "$SNAP_FMT" 2>/dev/null)
  [ ${#raw[@]} -gt 0 ] || return 0

  # Session list first, alphabetical and filtered, so rows keep a stable order
  # and the jump keys stay put between ticks.
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    SESSIONS+=("$sess"); P_PANE+=(""); P_CMD+=(""); P_CX+=(0); P_CY+=(0)
    P_TITLE+=(""); P_RANK+=(-1)
  done < <(printf '%s\n' "${raw[@]}" |
             cut -d"$SNAP_SEP" -f2 |
             sort -u |
             grep -vx "$MON" |
             { if [ -n "$MONITOR_FILTER" ]; then grep -E "$MONITOR_FILTER"; else cat; fi })

  n=${#SESSIONS[@]}
  [ "$n" -gt 0 ] || return 0

  # Then the best pane for each. The running process is the truth -- automatic
  # rename means the window is often not called "claude" at all -- so a pane
  # running Claude outranks a pane merely sitting in a window named for it, and
  # among equals the active one wins.
  for line in "${raw[@]}"; do
    IFS="$SNAP_SEP" read -r spid sess wact pid pact cx cy cmd wname title <<<"$line"
    [ -n "$spid" ] && SERVER_PID=$spid
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "${SESSIONS[$i]}" = "$sess" ] && break
      i=$((i + 1))
    done
    [ "$i" -lt "$n" ] || continue

    rank=0
    if is_claude_cmd "$cmd"; then rank=400
    elif is_claude_host "$cmd" && title_is_claude "$title"; then rank=300
    elif [ "$wname" = "$MONITOR_WINDOW" ]; then rank=200
    fi
    [ "$wact" = 1 ] && rank=$((rank + 20))
    [ "$pact" = 1 ] && rank=$((rank + 2))

    if [ "$rank" -gt "${P_RANK[$i]}" ]; then
      P_RANK[$i]=$rank; P_PANE[$i]=$pid; P_CMD[$i]=$cmd
      P_CX[$i]=$cx; P_CY[$i]=$cy; P_TITLE[$i]=$title
    fi
  done
}

P_BUSY=()   # per session: 1 when the title says Claude is mid-turn

# Decides, for every session at once, whether its title says Claude is working.
# Claude sets the title to "<braille frame> <task summary>" for the whole turn
# and swaps the frame for "✳" the moment it stops, so the leading glyph is the
# signal -- and the test is the whole braille block rather than a list of frames,
# so it survives Claude picking one we have not seen.
#
# One perl for all sessions, not one each: at twenty sessions that was twenty
# forks a tick, some 5ms apiece, to inspect one character.
monitor_busy_titles() {
  local i n=${#SESSIONS[@]} feed=""
  P_BUSY=()
  i=0
  while [ "$i" -lt "$n" ]; do P_BUSY+=(0); i=$((i + 1)); done
  [ "$n" -gt 0 ] || return 0

  if command -v perl >/dev/null 2>&1; then
    i=0
    while [ "$i" -lt "$n" ]; do
      feed+="$i	${P_TITLE[$i]}"$'\n'
      i=$((i + 1))
    done
    while IFS= read -r i; do
      [ -n "$i" ] && P_BUSY[$i]=1
    done < <(printf '%s' "$feed" | perl -CSD -ne '
               chomp;
               my ($i, $t) = split(/\t/, $_, 2);
               next unless defined $t && length $t;
               my $c = ord(substr($t, 0, 1));
               print "$i\n" if $c >= 0x2800 && $c <= 0x28FF;')
    return 0
  fi

  # No perl: the frames we know about, matched on the first character. bash
  # counts characters here only in a UTF-8 locale; elsewhere this degrades to
  # matching any Claude glyph, which reads a settled session as working.
  i=0
  while [ "$i" -lt "$n" ]; do
    case $BRAILLE_FRAMES in *"${P_TITLE[$i]:0:1}"*) P_BUSY[$i]=1 ;; esac
    i=$((i + 1))
  done
}

# There used to be an age column here, seconds since #{window_activity} formatted
# as 12d3h. It was dropped: a working session streams output constantly, so its
# activity timestamp keeps bumping and the column read 0s however long the turn
# had run -- the one number you actually want it to show.

# --- exported state ----------------------------------------------------------
#
# What claude/monitor-hook.sh and claude/statusline.sh leave behind, one pair of
# files per pane. Reading them costs no forks at all -- they are a handful of
# key=value lines each and bash reads them itself -- so this is nearly free next
# to the capture-pane the screen needs anyway.
#
# Everything here is advisory. A session on another machine, one started before
# the hooks were installed, or one whose Claude was killed before SessionEnd will
# have no file or a stale one, and the monitor falls back to what it can see.

X_STATE=()    # per session, same order as SESSIONS: state from Claude's events
X_DETAIL=()
X_CTX=()      # and the numbers the screen does not carry
X_COST=()
X_COSTF=()    # the same cost, rounded for the column, so the draw does no work
X_COST_ALL="" # every session's cost added up, for the line under the rows
X_ACCT=()     # per session: the account its export was written under
X_LIM5=""     # the fallback pair, for sessions whose account is not known; the
X_LIM7=""     # rest are per account, in the ACC_* table below
X_RST5=""     # already formatted for the header; see monitor_fmt_reset
X_RST7=""
X_AGENTS=()   # per session: subagents in flight; see monitor_count_agents
X_AGENT_ALL=0 # and the fleet's, which belongs in the header rather than a row
X_ASPEND=()   # per session: cents its subagents have spent; monitor_sum_spend
X_ASPEND_ALL=0
# The two are not the same quantity and are deliberately not shown in the same
# column. The count is what is in flight now and falls back to zero; the spend is
# cumulative over the session and does not, so a session with nothing running can
# still have a figure. Both are the fleet's business rather than a row's, which
# is why they end up side by side in the header and nowhere else.
#
# This spend is a breakout of the cost column above, not an addition to it: every
# subagent's tokens are already inside its session's total_cost_usd. Adding the
# two together would count the agents twice.
# Spend is split by how the session is paying, because on a subscription the two
# mean completely different things. A subscription session's cost is notional --
# what those tokens would have cost at API rates -- and nothing is billed for it;
# the limits are the real constraint. An API-billed session's cost is money. A
# personal subscription never silently crosses over: hitting the limit stops the
# session and tells you to run /login for an API-billed account, so anything in
# the API column got there because someone chose it.
X_COST_SUB=""
X_COST_API=""
X_COST_OVER=""   # spend the exporter attributed to an exhausted window
X_NOTICE=""      # a limit notice read off some session's screen

# --- accounts -----------------------------------------------------------------
#
# The limits used to be treated as one pair for the whole screen, on the grounds
# that they are account-wide and every session therefore reports the same two
# numbers. That holds for exactly as long as there is one account.
#
# With more than one it is wrong in a way that is worse than useless, because the
# numbers still look right. Whichever session answered last wins the header, so a
# fleet split across two subscriptions shows one of them and calls it the total --
# and it changes which one behind your back, every time the other side answers.
# The same thing happens on a single config dir: /login rewrites it in place, and
# for a while afterwards half the fleet is still reporting the account you just
# left. That is the case worth catching, since nothing on the screen would
# otherwise say the reading had gone stale.
#
# So the readings are grouped by the account they were taken under, and each
# account gets its own line. Parallel arrays rather than a structure: bash 3.2 has
# no associative arrays, and there are only ever a handful of these.
#
# The key is the account's email address, except for two cases that have to be
# kept out of the subscription lines. An API-billed session is keyed "api": it has
# no rate limits at all, and grouping it under whichever address the config
# happens to hold would put a session that is not on the subscription onto the
# subscription's line. A session that has not said -- no exporter, or no answer
# yet -- is keyed empty, and its readings go to the X_LIM5/X_LIM7 fallback so an
# older setup keeps the header it had before this existed.
ACC_KEY=()    # the account, as the status line exported it
ACC_N=()      # live sessions signed in to it
ACC_LIM5=(); ACC_LIM7=()
ACC_RST5=(); ACC_RST7=()   # formatted, like X_RST5
ACC_TS=()     # write time of the reading held above, so the newest one wins
ACC_TAG=()    # short label for the session rows; see monitor_acc_tags
ACC_SHOWN=0   # accounts with a line of their own, i.e. not "api" and not unknown

# The notices Claude Code puts up about limits and extra usage. These are matched
# rather than any field, because the field does not exist anywhere reachable:
# isUsingOverage lives only inside the process, and its own renderer returns
# nothing at all for the ordinary in-overage case -- a message appears only near
# the overage cap or once something has been refused. So this catches the loud
# half, and the exporter's arithmetic covers the quiet half.
#
# Matched as whole phrases, since the bottom of the screen also holds Claude's
# own prose and "you've reached your" is a sentence anyone might write.
LIMIT_NOTICES='close to your usage limit|close to your usage credit limit|out of extra usage|out of usage credits|hit your monthly spend limit|hit your usage limit|monthly spend limit|now using extra usage'

# Epoch -> local clock, remembered so this costs a fork only when the window
# actually rolls over. The header is rebuilt on every keystroke and must not
# fork; these are computed on the refresh tick instead.
#
# Cached by epoch and format together rather than in a slot per window: with two
# accounts on screen there are two of each window, all four are formatted every
# tick, and a two-slot memo would miss on every one of them. Keyed by format as
# well because the two windows are shown in different shapes.
FMT_OUT=""
FMTC_K=()
FMTC_V=()

# Whether a window's reset is still ahead of us, i.e. the reading that came with
# it describes the window we are in. An unreadable or absent epoch counts as
# pending: an old Claude that never sent one should not have all its numbers
# thrown away.
monitor_reset_pending() {
  case ${1:-} in
    ''|0|*[!0-9]*) return 0 ;;
    *) [ "$1" -ge "${2:-0}" ] ;;
  esac
}
monitor_fmt_reset() {
  # date -r takes an epoch on BSD and a filename on GNU, so the GNU spelling is
  # the fallback rather than the other way round.
  FMT_OUT=$(date -r "$1" "+$2" 2>/dev/null) ||
    FMT_OUT=$(date -d "@$1" "+$2" 2>/dev/null) ||
    FMT_OUT=""
}

# Reads one key=value file into KV_*. Values may contain "=" -- read gives the
# last variable the unsplit remainder -- but not newlines; the hook flattens
# those before writing for exactly this reason.
KV_STATE=""; KV_DETAIL=""; KV_TS=0
KV_CTX=""; KV_COST=""; KV_LIM5=""; KV_LIM7=""
KV_RST5=""; KV_RST7=""; KV_SUB=""; KV_SESSION=""; KV_ACCT=""
monitor_read_kv() {
  local f=$1 k v
  [ -r "$f" ] || return 1
  while IFS='=' read -r k v; do
    case $k in
      state)   KV_STATE=$v ;;
      detail)  KV_DETAIL=$v ;;
      ctx)     KV_CTX=$v ;;
      cost)    KV_COST=$v ;;
      over)    KV_OVER=$v ;;
      lim5)    KV_LIM5=$v ;;
      lim7)    KV_LIM7=$v ;;
      rst5)    KV_RST5=$v ;;
      rst7)    KV_RST7=$v ;;
      sub)     KV_SUB=$v ;;
      acct)    KV_ACCT=$v ;;
      session) KV_SESSION=$v ;;
      ts)      KV_TS=$v ;;
    esac
  done < "$f"
  return 0
}

# The tick's clock, read once and shared: bash 3.2 has no $EPOCHSECONDS, and both
# the age of an exported state and the ledger's idea of "today" need it. A fork
# per session -- or one per consumer -- would cost more than reading every file
# they look at.
MON_NOW=0
MON_DAY=""
monitor_clock() {
  local out
  out=$(date '+%s %F' 2>/dev/null) || return 1
  read -r MON_NOW MON_DAY <<<"$out"
  [ -n "$MON_NOW" ]
}

# --- parked jobs --------------------------------------------------------------
#
# What is in a pane is not always what is doing the work. Handed something long,
# Claude parks it: a background session is started under its daemon and the pane
# shows that session instead. The daemon does not pass $TMUX_PANE on, so the
# session actually working -- spending the money, running the agents -- has no
# pane to be keyed by, and the pane's own export freezes at the moment it parked.
# A row showing that export is not stale by a little: it is the wrong session.
#
# Claude keeps a registry that closes the gap, one small JSON file per running
# session in $SESSION_DIR. The session in the pane carries a parkedJobId, and the
# session doing the work carries the matching jobId along with its own session id
# -- which is the key its exports are filed under. So: pane -> its session id ->
# parkedJobId -> jobId -> the background session's export.
#
# The whole registry is read once a tick into two flat indexes, since bash 3.2 on
# this laptop has no associative arrays. A few dozen one-line files read by bash
# itself, so this costs no forks either.
PARKED_BY_SID=" "   # " <session id>:<parked job id> " for each that has parked one
SID_BY_JOB=" "      # " <job id>:<session id> " for each background session

# One string field out of one line of flat JSON, without a fork. Keys are matched
# with the punctuation in front of them, or "jobId" would find "parkedJobId" -- a
# session would then be read as the parked job of itself. A value with an escaped
# quote in it would come back short, which is why this is only ever used for ids.
JSTR=""
monitor_json_str() {
  local line=$1 k=$2 rest
  JSTR=""
  case $line in
    *",\"$k\":\""*) rest=${line#*",\"$k\":\""} ;;
    *"{\"$k\":\""*) rest=${line#*"{\"$k\":\""} ;;
    *) return 1 ;;
  esac
  JSTR=${rest%%'"'*}
  [ -n "$JSTR" ]
}

# Fills the two indexes. A registry that is not there at all -- another machine's
# monitor directory, an older Claude -- leaves them empty and every pane then
# reads as unparked, which is what it was before this existed.
monitor_read_sessions() {
  local f line sid job
  PARKED_BY_SID=" "; SID_BY_JOB=" "
  [ -d "$SESSION_DIR" ] || return 0
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    # Not `read ... || continue`: these files carry no trailing newline, so read
    # reports failure on the very line it just handed us.
    line=""
    IFS= read -r line < "$f" || true
    [ -n "$line" ] || continue
    monitor_json_str "$line" sessionId || continue
    sid=$JSTR
    monitor_json_str "$line" parkedJobId && PARKED_BY_SID+="$sid:$JSTR "
    monitor_json_str "$line" jobId && SID_BY_JOB+="$JSTR:$sid "
  done
  return 0
}

LOOKUP=""
monitor_index_get() { # value for $2 in index $1, or ""
  local rest
  LOOKUP=""
  case $1 in
    *" $2:"*) rest=${1#*" $2:"}; LOOKUP=${rest%% *} ;;
  esac
}

# Where the session in this pane has parked its work, if it has: the prefix its
# files are under, or "" to stay with the pane's own.
PARKED_BASE=""
monitor_parked_base() {
  local sid=$1 job cand
  PARKED_BASE=""
  [ -n "$sid" ] || return 0
  monitor_index_get "$PARKED_BY_SID" "$sid"; job=$LOOKUP
  [ -n "$job" ] || return 0
  monitor_index_get "$SID_BY_JOB" "$job"; sid=$LOOKUP
  [ -n "$sid" ] || return 0
  cand="$MONITOR_DIR/sess-$sid"
  # Only once it has exported something. A job that has finished, or one on a
  # machine where the exporters are not installed, leaves nothing here -- and the
  # pane's own numbers, old as they are, are then the best there is.
  { [ -r "$cand.state" ] || [ -r "$cand.meta" ]; } && PARKED_BASE=$cand
  return 0
}

# How many subagents the pane's session has in flight: one empty file per agent,
# left in $base.agents by monitor-hook.sh on SubagentStart and removed on
# SubagentStop. A glob, so it costs no forks -- and no arithmetic on our side,
# since the hook has already done the counting by naming the files.
#
# Not aged like the state file. A session that spawns five background agents and
# goes quiet waiting on them stops writing state long before they finish, and
# expiring the count would blank it on exactly the sessions it is there for. What
# guards it instead is the pane: a leftover directory can only be read as this
# session's if Claude is still up in that pane, and monitor_collect drops the
# count for a pane that is not running one.
AGENT_N=0
monitor_count_agents() {
  local f
  AGENT_N=0
  for f in "$1"/*; do
    [ -e "$f" ] || continue
    AGENT_N=$((AGENT_N + 1))
  done
}

# What those agents cost: one line of cents per finished agent, appended by
# monitor-hook.sh as each one stops. Summed here rather than kept as a total on
# the writing side, because several agents stop at once and only the append is
# safe between them -- see the subagent spend section of the hook.
#
# Read by bash, so it costs no forks: a line is a handful of bytes and even a
# session that has run hundreds of agents is a couple of kilobytes. A line that
# is not a plain number is skipped rather than trusted; a half-written one cannot
# occur, but a leftover from something else could.
ASPEND_C=0
monitor_sum_spend() {
  local line
  ASPEND_C=0
  [ -r "$1" ] || return 0
  while read -r line; do
    case $line in ''|*[!0-9]*) continue ;; esac
    ASPEND_C=$((ASPEND_C + line))
  done < "$1"
  return 0
}

# Where an account sits in the table, in ACC_I. Linear, because the table is a
# handful of entries and an index over it would cost more to build than to scan.
ACC_I=-1
monitor_acc_find() {
  local key=$1 i=0 n=${#ACC_KEY[@]}
  ACC_I=-1
  while [ "$i" -lt "$n" ]; do
    [ "${ACC_KEY[$i]}" = "$key" ] && { ACC_I=$i; return 0; }
    i=$((i + 1))
  done
  return 1
}

# The same, adding the account if it is not there yet.
monitor_acc_slot() {
  monitor_acc_find "$1" && return 0
  ACC_I=${#ACC_KEY[@]}
  ACC_KEY+=("$1"); ACC_N+=(0)
  ACC_LIM5+=(""); ACC_LIM7+=("")
  ACC_RST5+=(""); ACC_RST7+=("")
  ACC_TS+=(0); ACC_TAG+=("")
  return 0
}

# Short labels for the session rows. The address itself is too wide to put on
# every row -- it would take a sixth of an 80-column screen -- so the part in
# front of the @ stands in for it, which is what tells accounts apart in every
# case that is not deliberately adversarial.
#
# Where it does not, because two addresses share a local part, both fall back to
# the front of the whole address. Two that are still the same after that read as
# one account on the rows; the lines under the header spell them out in full, and
# that is the place to look when the tags do not add up.
ACC_TAGW=8
monitor_acc_tags() {
  local i=0 j n=${#ACC_KEY[@]} t
  while [ "$i" -lt "$n" ]; do
    t=${ACC_KEY[$i]%%@*}
    ACC_TAG[$i]=${t:0:$ACC_TAGW}
    i=$((i + 1))
  done
  # Compared after truncation, since that is what ends up on the screen: two
  # addresses that first differ past the eighth character collide here just as
  # much as two that are identical.
  i=0
  while [ "$i" -lt "$n" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$n" ]; do
      if [ -n "${ACC_TAG[$i]}" ] && [ "${ACC_TAG[$i]}" = "${ACC_TAG[$j]}" ]; then
        ACC_TAG[$i]=${ACC_KEY[$i]:0:$ACC_TAGW}
        ACC_TAG[$j]=${ACC_KEY[$j]:0:$ACC_TAGW}
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# Which accounts get a line, and in what order: alphabetical, so a line does not
# jump because a session on some other account came or went.
#
# Left out are the two keys that are not subscriptions to report on -- "api",
# which has no limits by construction, and the unknown account, whose reading
# goes to the header instead -- and any account with nothing live on it, which is
# how a meta file left behind by a session that has since died stops being drawn
# as an account you are signed in to.
ACC_ORDER=()
ACC_TAGGED=0
monitor_acc_order() {
  local i=0 n=${#ACC_KEY[@]} j k t
  ACC_ORDER=(); ACC_SHOWN=0; ACC_TAGGED=0
  while [ "$i" -lt "$n" ]; do
    if [ "${ACC_N[$i]}" -gt 0 ] && [ -n "${ACC_KEY[$i]}" ]; then
      ACC_TAGGED=$((ACC_TAGGED + 1))
      if [ "${ACC_KEY[$i]}" != api ]; then
        j=${#ACC_ORDER[@]}
        ACC_ORDER+=("$i")
        while [ "$j" -gt 0 ]; do
          k=$((j - 1))
          [[ ${ACC_KEY[${ACC_ORDER[$k]}]} > ${ACC_KEY[${ACC_ORDER[$j]}]} ]] || break
          t=${ACC_ORDER[$j]}; ACC_ORDER[$j]=${ACC_ORDER[$k]}; ACC_ORDER[$k]=$t
          j=$k
        done
      fi
    fi
    i=$((i + 1))
  done
  ACC_SHOWN=${#ACC_ORDER[@]}
}

# Fills the X_* arrays for every session, and the ACC_* table behind them.
monitor_read_exports() {
  local i n=${#SESSIONS[@]} now base acck subc=0 apic=0 overc=0 allc=0
  local seen_sub="" seen_api="" seen_any=""
  X_STATE=(); X_DETAIL=(); X_CTX=(); X_COST=(); X_COSTF=(); X_AGENTS=()
  X_ASPEND=(); X_ACCT=()
  ACC_KEY=(); ACC_N=(); ACC_LIM5=(); ACC_LIM7=(); ACC_RST5=(); ACC_RST7=()
  ACC_TS=(); ACC_TAG=(); ACC_ORDER=(); ACC_SHOWN=0; ACC_TAGGED=0
  X_LIM5=""; X_LIM7=""; X_RST5=""; X_RST7=""
  X_COST_SUB=""; X_COST_API=""; X_COST_OVER=""; X_COST_ALL=""; X_NOTICE=""
  X_AGENT_ALL=0; X_ASPEND_ALL=0
  i=0
  while [ "$i" -lt "$n" ]; do
    X_STATE+=(""); X_DETAIL+=(""); X_CTX+=(""); X_COST+=(""); X_COSTF+=("")
    X_AGENTS+=(0); X_ASPEND+=(0); X_ACCT+=("")
    i=$((i + 1))
  done
  [ "$n" -gt 0 ] && [ -d "$MONITOR_DIR" ] || return 0

  now=$MON_NOW
  [ "$now" -gt 0 ] 2>/dev/null || return 0
  monitor_read_sessions
  i=0
  while [ "$i" -lt "$n" ]; do
    base="$MONITOR_DIR/${SERVER_PID}-${P_PANE[$i]#%}"

    # Which session is in this pane, and whether what it is showing is really
    # somewhere else -- see the parked jobs section. The state file is asked first
    # because it exists from a session's very first event, where the metadata one
    # waits for a status line to render; both carry the id.
    KV_SESSION=""
    monitor_read_kv "$base.state" || true
    [ -n "$KV_SESSION" ] || monitor_read_kv "$base.meta" || true
    monitor_parked_base "$KV_SESSION"
    [ -n "$PARKED_BASE" ] && base=$PARKED_BASE

    monitor_count_agents "$base.agents"
    X_AGENTS[$i]=$AGENT_N
    monitor_sum_spend "$base.aspend"
    X_ASPEND[$i]=$ASPEND_C

    KV_STATE=""; KV_DETAIL=""; KV_TS=0
    if monitor_read_kv "$base.state" &&
       [ $((now - KV_TS)) -lt "$MONITOR_STALE" ] 2>/dev/null; then
      X_STATE[$i]=$KV_STATE
      X_DETAIL[$i]=$KV_DETAIL
    fi

    # The metadata half is not aged the same way. Its numbers only move when
    # Claude answers, so a quiet session's context and cost stay true for as long
    # as it stays quiet -- expiring them would blank the column on exactly the
    # sessions that have been sitting there longest.
    KV_CTX=""; KV_COST=""; KV_LIM5=""; KV_LIM7=""; KV_TS=0
    KV_RST5=""; KV_RST7=""; KV_SUB=""; KV_OVER=""; KV_ACCT=""
    if monitor_read_kv "$base.meta"; then
      X_CTX[$i]=$KV_CTX
      X_COST[$i]=$KV_COST

      # Which account this reading was taken under, and so which account's
      # windows it describes. An API-billed session is keyed apart from the
      # subscriptions whatever address the config holds, because it is not
      # spending against any of them; see the accounts section.
      case $KV_SUB in
        0) acck=api ;;
        *) acck=$KV_ACCT ;;
      esac
      X_ACCT[$i]=$acck
      monitor_acc_slot "$acck"

      # The limits are account-wide, so every session on one account reports the
      # same pair -- but each only rewrites its file when its own status line
      # runs, so the files disagree by however long ago that was. Take them from
      # the newest file on that account rather than from whichever session
      # happens to be read last, which is alphabetical order and could be
      # minutes out of date.
      #
      # A fresh write timestamp is not enough to trust them, though. These
      # numbers come from the last API response that session received, so a
      # session sitting idle across a window rollover keeps re-exporting the old
      # window's usage with a new timestamp on it -- most of the fleet reads that
      # way most of the time. The reset epoch is what gives it away: once it is
      # in the past the reading has been superseded, whatever its timestamp says.
      # Better no number than last window's, so a superseded one is skipped
      # rather than aged into second place.
      case $KV_TS in
        ''|*[!0-9]*) ;;
        *)
          if [ "$KV_TS" -gt "${ACC_TS[$ACC_I]}" ] &&
             [ -n "$KV_LIM5$KV_LIM7" ] && [ "$KV_LIM5" != -1 ] &&
             monitor_reset_pending "$KV_RST5" "$now"; then
            ACC_TS[$ACC_I]=$KV_TS
            ACC_LIM5[$ACC_I]=$KV_LIM5
            ACC_LIM7[$ACC_I]=$KV_LIM7
            monitor_reset_texts "$KV_RST5" "$KV_RST7"
            ACC_RST5[$ACC_I]=$RST5_OUT
            ACC_RST7[$ACC_I]=$RST7_OUT
          fi
          ;;
      esac
      # Into whichever column this session is paying from. A session that has not
      # answered yet reports neither, and is left out rather than guessed at.
      case $KV_COST in
        ''|*[!0-9.]*) ;;
        *)
          monitor_cents "$KV_COST"
          # Rounded here rather than in the draw: the draw reruns on every
          # keystroke and the arithmetic would be repeated for nothing.
          printf -v X_COSTF[$i] '$%d.%02d' $((CENTS / 100)) $((CENTS % 100))
          allc=$((allc + CENTS)); seen_any=1
          case $KV_SUB in
            1) subc=$((subc + CENTS)); seen_sub=1 ;;
            0) apic=$((apic + CENTS)); seen_api=1 ;;
          esac
          ;;
      esac
      case $KV_OVER in
        ''|*[!0-9.]*) ;;
        *) monitor_cents "$KV_OVER"; overc=$((overc + CENTS)) ;;
      esac
    fi
    i=$((i + 1))
  done
  # The header's fallback pair: the reading from sessions that did not say which
  # account it came from -- a Claude older than the acct= key, or one whose
  # status line has not run since this was installed. Drawn only when no account
  # identified itself at all, so an installation without any of this keeps the
  # header it had before; where some sessions do name an account, they get lines
  # and this reading is dropped rather than shown as a nameless third window.
  if monitor_acc_find ""; then
    X_LIM5=${ACC_LIM5[$ACC_I]}
    X_LIM7=${ACC_LIM7[$ACC_I]}
    X_RST5=${ACC_RST5[$ACC_I]}
    X_RST7=${ACC_RST7[$ACC_I]}
  fi
  [ "$overc" -gt 0 ] && printf -v X_COST_OVER '%d.%02d' $((overc / 100)) $((overc % 100))
  # Formatted only if something landed there, so an absent column stays absent
  # rather than reading $0.00 -- which would look like a measurement.
  [ -n "$seen_sub" ] && printf -v X_COST_SUB '%d.%02d' $((subc / 100)) $((subc % 100))
  [ -n "$seen_api" ] && printf -v X_COST_API '%d.%02d' $((apic / 100)) $((apic % 100))
  [ -n "$seen_any" ] && printf -v X_COST_ALL '%d.%02d' $((allc / 100)) $((allc % 100))
  return 0
}

# One epoch, formatted, through the cache above -- so this forks only when a
# window actually rolls over, not once per account per tick. An epoch that is not
# one comes back empty rather than as whatever date would make of it.
RST_OUT=""
monitor_reset_text() {
  local e=$1 f=$2 k i=0 n=${#FMTC_K[@]}
  RST_OUT=""
  case $e in ''|0|*[!0-9]*) return 0 ;; esac
  k="$e $f"
  while [ "$i" -lt "$n" ]; do
    [ "${FMTC_K[$i]}" = "$k" ] && { RST_OUT=${FMTC_V[$i]}; return 0; }
    i=$((i + 1))
  done
  # Two entries per account per rollover, so this grows by a handful a day on a
  # monitor left up for one. Dropped wholesale rather than aged: the next tick
  # refills whatever is still current, at the cost of one fork each.
  [ "$n" -gt 32 ] && { FMTC_K=(); FMTC_V=(); }
  monitor_fmt_reset "$e" "$f"
  RST_OUT=$FMT_OUT
  FMTC_K+=("$k"); FMTC_V+=("$RST_OUT")
  return 0
}

# The pair, into RST5_OUT and RST7_OUT. The 5-hour window is shown as a clock
# time and the weekly one as a day, since one is always today and the other
# rarely is.
RST5_OUT=""; RST7_OUT=""
monitor_reset_texts() {
  monitor_reset_text "$1" '%-l:%M%p'; RST5_OUT=$RST_OUT
  monitor_reset_text "$2" '%a %-l%p'; RST7_OUT=$RST_OUT
}

# "1.234" -> CENTS=123. Assigns rather than prints: a $(...) per session to add up
# a column of numbers is a fork per session, which cost more than reading all the
# files put together. Truncates rather than rounds -- this is a running total for
# a header, not an invoice.
CENTS=0
monitor_cents() {
  local v=$1 whole frac
  case $v in
    *.*) whole=${v%%.*}; frac=${v#*.} ;;
    *)   whole=$v; frac=0 ;;
  esac
  frac=${frac}00
  frac=${frac:0:2}
  case $whole in ''|*[!0-9]*) whole=0 ;; esac
  case $frac in ''|*[!0-9]*) frac=0 ;; esac
  CENTS=$((10#$whole * 100 + 10#$frac))
}

# --- spend ledger --------------------------------------------------------------
#
# What claude/statusline.sh files under $MONITOR_DIR/spend: one "<day>.<session>"
# per session per day, holding the cents that session spent on that day. Unlike
# the per-pane exports, these outlive the session that wrote them, which is the
# whole point -- the cost column adds up what is running now, and this adds up
# what has been spent, whether or not anything is still up to show for it.
#
# Today's spend is inside these totals as well, since a live session rewrites its
# file as it goes. So "total" and "today" overlap on purpose: one is the sessions
# on screen, the other the day they are part of.
#
# Each file records how its session was paying as well, so the windows carry the
# same sub/api split as the live line rather than one lump per window.
LEDGER_DIR="$MONITOR_DIR/spend"

# One row per window, in the order they are drawn. Already formatted, like the
# other totals: the draw does no arithmetic.
SPEND_LBL=(today 7d 30d all)
SPEND_ALL=("" "" "" "")
SPEND_SUB=("" "" "" "")
SPEND_API=("" "" "" "")

# Days before today are frozen -- a session past midnight writes to the new day's
# file -- so their sums are computed once and held until the day rolls over,
# leaving each tick with only today's handful of files to read. Indexed 0..2 for
# 7d, 30d and all-time, today excluded from every one of them.
LDG_DAY=""     # the day those sums were computed for
LDG_P_ALL=(0 0 0)
LDG_P_SUB=(0 0 0)
LDG_P_API=(0 0 0)
LDG_CUT7=""    # the oldest day each window includes, blank if date could not say
LDG_CUT30=""
LDG_ANY=""     # whether the ledger holds anything at all; see below

# $1 days back as a local date, BSD spelling first and GNU second -- the same
# order as monitor_fmt_reset, and for the same reason.
DAY_AGO=""
monitor_day_ago() {
  DAY_AGO=$(date -v-"$1"d '+%F' 2>/dev/null) ||
    DAY_AGO=$(date -d "$1 days ago" '+%F' 2>/dev/null) ||
    DAY_AGO=""
}

day_ge() { [ "$1" = "$2" ] || [[ $1 > $2 ]]; }

# Cents and payment kind out of one ledger file. Read by bash itself, so a day of
# files costs no forks at all. LDG_SUB is 1 subscription, 0 API-billed, -1 for a
# session that never got far enough to say -- the same three values the status
# line exports, and the third is counted in the total and in neither column.
LDG_CENTS=0
LDG_SUB=-1
monitor_ledger_file() {
  local k v
  LDG_CENTS=0; LDG_SUB=-1
  [ -r "$1" ] || return 1
  while IFS='=' read -r k v; do
    case $k in
      spent) LDG_CENTS=$v ;;
      sub)   LDG_SUB=$v ;;
    esac
  done < "$1"
  case $LDG_CENTS in ''|*[!0-9]*) LDG_CENTS=0 ;; esac
  case $LDG_SUB in 0|1) ;; *) LDG_SUB=-1 ;; esac
  return 0
}

# Adds the file just read into window $1 of the cached past sums.
monitor_ledger_add() {
  LDG_P_ALL[$1]=$((${LDG_P_ALL[$1]} + LDG_CENTS))
  case $LDG_SUB in
    1) LDG_P_SUB[$1]=$((${LDG_P_SUB[$1]} + LDG_CENTS)) ;;
    0) LDG_P_API[$1]=$((${LDG_P_API[$1]} + LDG_CENTS)) ;;
  esac
}

# Sums every day but today, for as long as today lasts.
monitor_ledger_rebuild() {
  local f b d
  LDG_DAY=$MON_DAY
  LDG_P_ALL=(0 0 0); LDG_P_SUB=(0 0 0); LDG_P_API=(0 0 0)
  monitor_day_ago 6;  LDG_CUT7=$DAY_AGO
  monitor_day_ago 29; LDG_CUT30=$DAY_AGO
  [ -d "$LEDGER_DIR" ] || return 0
  for f in "$LEDGER_DIR"/*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    d=${b%%.*}
    # A name that is not "<iso day>.<something>" is not ours: a temp file caught
    # mid-rename, or whatever else ends up in the directory.
    case $b in "$d") continue ;; esac
    case $d in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    LDG_ANY=1
    [ "$d" = "$MON_DAY" ] && continue
    monitor_ledger_file "$f" || continue
    monitor_ledger_add 2
    [ -n "$LDG_CUT30" ] && day_ge "$d" "$LDG_CUT30" && monitor_ledger_add 1
    [ -n "$LDG_CUT7" ] && day_ge "$d" "$LDG_CUT7" && monitor_ledger_add 0
  done
  return 0
}

# "$1 cents" -> LDG_FMT="12.34". One place, because the rows below want it a
# dozen times and a $(...) each would be a dozen forks a tick.
LDG_FMT=""
monitor_ledger_fmt() { printf -v LDG_FMT '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

# Today's files every tick, the rest from the cache above, then the four rows.
monitor_read_ledger() {
  local f i t_all=0 t_sub=0 t_api=0 c
  SPEND_ALL=("" "" "" ""); SPEND_SUB=("" "" "" ""); SPEND_API=("" "" "" "")
  [ -n "$MON_DAY" ] && [ -d "$LEDGER_DIR" ] || return 0
  [ "$LDG_DAY" = "$MON_DAY" ] || monitor_ledger_rebuild

  for f in "$LEDGER_DIR/$MON_DAY".*; do
    [ -f "$f" ] || continue
    LDG_ANY=1
    monitor_ledger_file "$f" || continue
    t_all=$((t_all + LDG_CENTS))
    case $LDG_SUB in
      1) t_sub=$((t_sub + LDG_CENTS)) ;;
      0) t_api=$((t_api + LDG_CENTS)) ;;
    esac
  done

  # An empty ledger reads as unknown rather than zero, the same way a session
  # that has not reported leaves its cost column blank: nobody has spent nothing
  # today, they have just not installed the exporter yet. Once there is a single
  # file, a quiet day is a real $0.00 and says so.
  [ -n "$LDG_ANY" ] || return 0

  # Row 0 is today alone; the rest are today plus the days behind them, which is
  # why every window is built from the same pair rather than summed twice.
  i=0
  while [ "$i" -lt 4 ]; do
    # 7d and 30d are dropped when date could not work out where they start --
    # better an absent row than one that quietly means something else.
    if { [ "$i" = 1 ] && [ -z "$LDG_CUT7" ]; } ||
       { [ "$i" = 2 ] && [ -z "$LDG_CUT30" ]; }; then
      i=$((i + 1)); continue
    fi
    case $i in
      0) c=0 ;;                 # today: nothing behind it
      *) c=$((i - 1)) ;;        # 7d, 30d, all: cached window i-1
    esac

    if [ "$i" = 0 ]; then
      monitor_ledger_fmt "$t_all"; SPEND_ALL[$i]=$LDG_FMT
      [ "$t_sub" -gt 0 ] && { monitor_ledger_fmt "$t_sub"; SPEND_SUB[$i]=$LDG_FMT; }
      [ "$t_api" -gt 0 ] && { monitor_ledger_fmt "$t_api"; SPEND_API[$i]=$LDG_FMT; }
    else
      monitor_ledger_fmt $((${LDG_P_ALL[$c]} + t_all)); SPEND_ALL[$i]=$LDG_FMT
      if [ $((${LDG_P_SUB[$c]} + t_sub)) -gt 0 ]; then
        monitor_ledger_fmt $((${LDG_P_SUB[$c]} + t_sub)); SPEND_SUB[$i]=$LDG_FMT
      fi
      if [ $((${LDG_P_API[$c]} + t_api)) -gt 0 ]; then
        monitor_ledger_fmt $((${LDG_P_API[$c]} + t_api)); SPEND_API[$i]=$LDG_FMT
      fi
    fi
    i=$((i + 1))
  done
  return 0
}

# Reconciles what the screen says with what Claude's own events say.
#
# Neither source wins outright, because each is blind where the other is not:
#
#   ask    whichever sees it first. The screen usually does -- Notification lags
#          the prompt by about six seconds, a refresh tick is two -- but the hook
#          catches prompts in a pane the classifier cannot read.
#   draft  screen only. No event fires for typing, and nothing in the payload
#          describes the input box.
#   shell  screen only, and final: no Claude, so an old file is just a leftover
#   other  from a session that has since exited.
#   gone
#   busy   the events, when fresh. They know a turn has started before any of it
#   idle   reaches the screen, and they are right about a pane whose title the
#          terminal never set.
monitor_merge() {
  local i=$1 xs=${X_STATE[$i]} xd=${X_DETAIL[$i]}

  [ -n "$xs" ] || return 0
  case $CLS_STATE in
    shell|other|gone) return 0 ;;
  esac

  if [ "$xs" = ask ] && [ "$CLS_STATE" != ask ]; then
    CLS_STATE=ask
    [ -n "$xd" ] && CLS_DETAIL=$xd
    return 0
  fi
  case $CLS_STATE in
    ask|draft) return 0 ;;
  esac
  case $xs in
    busy|idle)
      CLS_STATE=$xs
      # The screen names a turn better than a tool name does -- "Fixing the
      # surface findings…" against "Bash" -- so the event's detail only fills a
      # gap it left.
      if [ -z "$CLS_DETAIL" ] && [ -n "$xd" ]; then CLS_DETAIL=$xd; fi
      ;;
  esac
  # Explicit, because every branch above ends in a test whose result would
  # otherwise become this function's status and read as failure to a caller.
  return 0
}

# Looks for a limit or extra-usage notice at the bottom of the pane just read,
# and keeps the first one found across the fleet for the header. Only the bottom
# few rows, where Claude puts its notices -- the transcript above them is full of
# sentences that would match.
monitor_scan_notice() {
  local j stop
  [ -z "$X_NOTICE" ] || return 0
  stop=$((L_N - 6)); [ "$stop" -lt 0 ] && stop=0
  j=$((L_N - 1))
  while [ "$j" -ge "$stop" ]; do
    if [[ ${LINES[$j]} =~ $LIMIT_NOTICES ]]; then
      monitor_strip "${LINES[$j]}"
      X_NOTICE=$STRIPPED
      return 0
    fi
    j=$((j - 1))
  done
  return 0
}

# --- state ------------------------------------------------------------------

LINES=()   # the visible rows of the pane being classified
L_N=0

# Claude separates the input box's prompt glyph from what you type with a
# non-breaking space, where a dialog's option rows use a plain one. It looks like
# a space on screen and is not one to the shell, so every place that steps over
# the glyph has to strip both -- getting this wrong left a stray byte on the front
# of the draft text and, worse, stopped the dim test below from ever finding the
# escape sequence it looks for.
NBSP=$'\302\240'

# Reads a pane's visible text into LINES, one row per element, no escape
# sequences. Indexing matters: capture-pane emits every row from the top of the
# screen, blanks included, so LINES[cursor_y] is the row the cursor is on.
monitor_read_pane() {
  local line
  LINES=(); L_N=0
  [ -n "${1:-}" ] || return 1
  while IFS= read -r line; do LINES+=("$line"); done \
    < <(tmux capture-pane -p -t "$1" 2>/dev/null)
  L_N=${#LINES[@]}
  [ "$L_N" -gt 0 ]
}

# Trims a row for display: leading whitespace and glyphs off, trailing space off.
STRIPPED=""
monitor_strip() {
  local s=$1
  while [ -n "$s" ]; do
    case ${s:0:1} in [[:alnum:]]) break ;; *) s=${s:1} ;; esac
  done
  while [ -n "$s" ]; do
    case ${s: -1} in [[:space:]]) s=${s%?} ;; *) break ;; esac
  done
  STRIPPED=$s
}

# What a live dialog is asking, read upwards from the row the cursor sits on.
# Taken from the screen rather than from a list of known wordings so that a
# prompt this script has never heard of still says something useful.
ASK_DETAIL=""
monitor_ask_detail() {
  local row=$1 i stop line tail fallback="" loose=""
  ASK_DETAIL=""
  stop=$((row - 14)); [ "$stop" -lt 0 ] && stop=0
  i=$((row - 1))
  while [ "$i" -ge "$stop" ]; do
    monitor_strip "${LINES[$i]}"
    line=$STRIPPED
    if [ -n "$line" ]; then
      case $line in
        *'?')                                 # "Do you want to create foo.txt?"
          # Claude's own questions arrive at the end of a wrapped paragraph, so
          # the line holding the "?" usually starts mid-sentence. Keep the last
          # sentence of it: the column is narrow and the question is the point.
          tail=${line##*'. '}
          case $tail in *'?') line=$tail ;; esac
          ASK_DETAIL=$line
          return 0
          ;;
        *'?'*) [ -n "$loose" ] || loose=$line ;;
      esac
      [ -n "$fallback" ] || fallback=$line    # else the dialog's own title
    fi
    i=$((i - 1))
  done
  ASK_DETAIL=${loose:-$fallback}
}

# Claude's status line, if it is on screen: "✢ Musing… (7s · ↓ 481 tokens)".
# It only shows before the reply starts streaming, so its absence means nothing.
#
# Read from the bottom up and only near the bottom, where the status line lives,
# and only where an ellipsis runs into the timer -- "Cooking… (13s · ". Scanning
# the whole screen for "(<digits>s · " matched transcript text instead: a session
# whose reply happened to quote a regex reported its own detail as
# "SURFACE|AMBIGUOUS|UNSUPPORTED|KEY)|question\(s\) sat". The same match decides
# busy, so the wrong line could also have invented a turn that was not running.
STATUS_DETAIL=""
monitor_status_detail() {
  local i stop line
  STATUS_DETAIL=""
  stop=$((L_N - 20)); [ "$stop" -lt 0 ] && stop=0
  i=$((L_N - 1))
  while [ "$i" -ge "$stop" ]; do
    line=${LINES[$i]}
    # Column 0 or it is not the status line. A tool still running prints the same
    # shape -- a command truncated to an ellipsis, then "(39s · 2 lines)" -- but
    # indented under its ⏺ row, and picking that up named the turn after whatever
    # grep it happened to be running.
    case $line in
      ''|[[:space:]]*) i=$((i - 1)); continue ;;
    esac
    if [[ $line == *'(esc to interrupt'* ]]; then   # pre-2.1 versions
      monitor_strip "${line%%'(esc to interrupt'*}"
      STATUS_DETAIL=$STRIPPED
      return 0
    fi
    # The timer is "(7s · " on a short turn and "(1h 49m 2s · " on a long one, so
    # the whole clock is matched loosely rather than as seconds alone -- which is
    # why a turn running over an hour used to lose its name off this line.
    if [[ $line =~ (.*…)\ \([0-9hms\ ]+·\  ]]; then
      monitor_strip "${BASH_REMATCH[1]}"
      STATUS_DETAIL=$STRIPPED
      return 0
    fi
    i=$((i - 1))
  done
  return 1
}

# The task summary out of a title, "⠂ Fix the parser" -> "Fix the parser".
# "Claude Code" is the placeholder title of a turn too young to have a summary
# yet, so it says nothing worth a column.
TITLE_DETAIL=""
monitor_title_detail() {
  local t=${1:-}
  TITLE_DETAIL=""
  title_is_claude "$t" || return 1
  t=${t#* }
  [ "$t" = 'Claude Code' ] && return 1
  monitor_strip "$t"
  TITLE_DETAIL=$STRIPPED
  [ -n "$TITLE_DETAIL" ]
}

# True when the text on a row is Claude's dim suggestion of what to type next
# rather than something a human typed. One capture of that single row is enough:
# the suggestion is rendered dim, typed text is not.
monitor_row_is_dim() {
  local raw after seq
  raw=$(tmux capture-pane -pe -t "$1" -S "$2" -E "$2" 2>/dev/null) || return 1
  case $raw in *'❯'*) after=${raw#*❯} ;; *) return 1 ;; esac
  after=${after#"$NBSP"}
  after=${after# }
  while [ "${after:0:2}" = "${ESC}[" ]; do
    seq=${after:2}
    case $seq in *m*) seq=${seq%%m*} ;; *) return 1 ;; esac
    case ";$seq;" in *';2;'*) return 0 ;; esac
    after=${after#*m}
  done
  return 1
}

# Footers a blocking dialog keeps on screen. Only consulted when the cursor is
# somewhere unrecognised, as a way of noticing a prompt that does not park it.
DIALOG_FOOTERS='[Ee]sc to (cancel|go back|close)|[Ee]nter to (confirm|approve|select|retry)'
# Wordings Claude asks with. A weak signal by itself -- it writes sentences like
# these in its replies too -- so it only counts alongside a dialog footer.
ASK_WORDS='Do you want|Would you like|Ready to code\?|Is this a project you created'

# monitor_classify <index> -> sets CLS_STATE and CLS_DETAIL from LINES and the
# snapshot. Assigns rather than prints "state|detail": the old packed form had to
# keep the free text last so a draft containing "|" could not shift the fields.
#
#   ask     Claude is waiting on a permission / plan / select prompt (actionable)
#   busy    Claude is generating
#   draft   text sitting in the prompt, unsent  (also actionable)
#   idle    Claude is up with an empty prompt
#   shell   just a shell
#   other   something else running (detail says what)
#   gone    session or pane disappeared
CLS_STATE=""
CLS_DETAIL=""
monitor_classify() {
  local i=$1 cmd=${P_CMD[$i]} cx=${P_CX[$i]} cy=${P_CY[$i]} title=${P_TITLE[$i]}
  local crow lead focus content bottom j stop grow row

  CLS_STATE=gone; CLS_DETAIL=""
  [ -n "${P_PANE[$i]}" ] || return 0
  [ -n "$cmd" ] || return 0

  # Not Claude: rank 300 and up is what the snapshot gives a pane it recognised
  # as Claude, so anything below that is whatever else happens to be running.
  if [ "${P_RANK[$i]}" -lt 300 ]; then
    case $cmd in
      zsh|-zsh|bash|-bash|sh|fish|login) CLS_STATE=shell ;;
      *) CLS_STATE=other; CLS_DETAIL=$cmd ;;
    esac
    return 0
  fi

  # Which widget has the keyboard, straight from where Claude parked the cursor.
  # This is the whole trick. Claude keeps the cursor in the input box at column
  # 0 when it is yours to type in, and moves it onto the selected row of a dialog
  # -- indented, inside the box -- when it is waiting on an answer. So focus, not
  # wording, decides whether a session is blocked.
  #
  # The wording could not: "Do you want ..." also appears in Claude's own replies
  # and in the transcript of prompts already answered, and the old test grepped
  # the whole screen for it *before* checking the spinner. A session that was
  # working, or one whose last reply merely ended in a question, showed up as the
  # loudest row on the monitor.
  # The row the keyboard belongs to is the cursor's own when it carries a prompt
  # glyph, and otherwise the nearest one above it: a draft long enough to wrap
  # leaves the cursor on a continuation row (which read as an empty prompt, so a
  # long draft showed up as idle), and a dialog that opens a text field leaves it
  # below the option it belongs to.
  crow=""; lead=""; focus=other; grow=-1
  j=$cy
  [ "$j" -ge "$L_N" ] && j=$((L_N - 1))
  stop=$((j - 12)); [ "$stop" -lt 0 ] && stop=0
  while [ "$j" -ge "$stop" ]; do
    row=${LINES[$j]}
    row=${row#"${row%%[! ]*}"}
    case $row in '❯'*|'>'*) crow=$row; grow=$j; break ;; esac
    j=$((j - 1))
  done

  if [ -n "$crow" ]; then
    lead=${crow#'❯'}; lead=${lead#'>'}
    # Which of the two that glyph belongs to. The separator is the giveaway: the
    # input box puts a non-breaking space after it, every dialog a plain one.
    # Column position cannot decide it -- a permission prompt indents its rows but
    # the dialog the AskUserQuestion tool puts up does not, so its selected row
    # sits at column 0 looking exactly like an input box, which is how a session
    # sitting on a question came to read as a draft of "1. Yes".
    #
    # Two weaker signals stand behind the separator so that losing it does not
    # turn every settled session into a NEEDS YOU: option rows are numbered, and
    # a dialog keeps the cursor on the glyph while the input box keeps it after
    # the separator.
    case $lead in
      "$NBSP"*) focus=input ;;
      ' '[0-9]*.*) focus=dialog ;;
      *) if [ "$grow" = "$cy" ] && [ "$cx" -le 1 ]; then focus=dialog; else focus=input; fi ;;
    esac
  fi

  # A dialog beats everything else: a pending question matters more than the
  # spinner, and one can be up mid-turn.
  if [ "$focus" = dialog ]; then
    monitor_ask_detail "$grow"
    CLS_STATE=ask; CLS_DETAIL=$ASK_DETAIL
    return 0
  fi

  # Cursor somewhere we do not recognise -- a full-screen view, or a dialog that
  # leaves the cursor alone. Read the bottom of the screen, which is where a live
  # prompt keeps its footer, and never the whole of it.
  if [ "$focus" = other ]; then
    bottom=""
    j=$((L_N - 8)); [ "$j" -lt 0 ] && j=0
    while [ "$j" -lt "$L_N" ]; do
      bottom+="${LINES[$j]}"$'\n'
      j=$((j + 1))
    done
    # A footer is enough on its own; the wording only counts next to an option
    # row, since Claude writes sentences like these in its replies as well.
    if [[ $bottom =~ $DIALOG_FOOTERS ]] ||
       { [[ $bottom =~ $ASK_WORDS ]] && [[ $bottom =~ ❯[[:space:]]*[0-9]+\. ]]; }; then
      monitor_ask_detail "$L_N"
      CLS_STATE=ask; CLS_DETAIL=$ASK_DETAIL
      return 0
    fi
  fi

  # Working. The title is what actually spans the turn: Claude's own footer hint
  # ("esc to interrupt") is gone as of 2.1.x, and the status line only shows
  # before the reply starts streaming. The status line is still read, because it
  # names the turn better than the title's summary does.
  if monitor_status_detail; then
    CLS_STATE=busy; CLS_DETAIL=$STATUS_DETAIL
    return 0
  fi
  if [ "${P_BUSY[$i]}" = 1 ]; then
    CLS_STATE=busy
    monitor_title_detail "$title" && CLS_DETAIL=$TITLE_DETAIL
    return 0
  fi

  # Idle, unless something is typed and unsent -- that one is waiting on a
  # keystroke, so it is worth surfacing.
  content=""
  if [ "$focus" = input ]; then
    # $lead is the row past the glyph, which the focus test above already took
    # off by pattern -- ${crow:1} would have counted characters, and that only
    # works out to one glyph in a UTF-8 locale.
    content=${lead#"$NBSP"}
    content=${content# }
    while [ -n "$content" ]; do
      case ${content: -1} in [[:space:]]) content=${content%?} ;; *) break ;; esac
    done
  fi

  if [ -n "$content" ]; then
    # Text on the prompt row is not proof anyone typed it. Claude fills the empty
    # box with a dim suggestion of what to ask next, which used to read as a
    # draft and made settled sessions look like they were waiting on a keystroke.
    #
    # The cursor settles it for free: typing moves it past the glyph, or off the
    # glyph's row entirely once the text wraps, while a suggestion leaves it
    # sitting at column 2. Only in that last case -- a suggestion, or a draft
    # whose cursor was moved home -- is a second capture worth it, to see whether
    # the text on that row is dim.
    if [ "$grow" != "$cy" ] || [ "$cx" -gt 2 ] ||
       ! monitor_row_is_dim "${P_PANE[$i]}" "$grow"; then
      CLS_STATE=draft; CLS_DETAIL=$content
      return 0
    fi
  fi

  # Nothing pending. The title's summary says what this session was last doing,
  # which beats what used to be here: the footer's "N agents" counter, which
  # reads the same in a session that has never run one.
  CLS_STATE=idle
  monitor_title_detail "$title" && CLS_DETAIL=$TITLE_DETAIL
  return 0
}

# Sets STATE_TEXT (fixed-width, ASCII on purpose: printf pads by bytes, so a
# multibyte glyph would break column alignment) and STATE_COLOR for state $1.
# It assigns rather than prints because the draw runs per row on every keystroke,
# and a $(...) per row is a fork per row. Text and color are separate because the
# highlighted row needs the text with no colour of its own -- an inner reset there
# would end the highlight halfway across the row.
monitor_state_style() {
  case $1 in
    ask)   STATE_TEXT='NEEDS YOU'; STATE_COLOR="${C_BOLD}${C_YEL}" ;;
    busy)  STATE_TEXT='working  '; STATE_COLOR=$C_CYA ;;
    draft) STATE_TEXT='draft    '; STATE_COLOR=$C_YEL ;;
    idle)  STATE_TEXT='idle     '; STATE_COLOR=$C_GRN ;;
    shell) STATE_TEXT='shell    '; STATE_COLOR=$C_DIM ;;
    other) STATE_TEXT='other    '; STATE_COLOR=$C_DIM ;;
    gone)  STATE_TEXT='gone     '; STATE_COLOR=$C_RED ;;
    *)     STATE_TEXT='?        '; STATE_COLOR=$C_DIM ;;
  esac
}

# --- rendering --------------------------------------------------------------

# Names and details are cut with ${x:0:n} rather than by a helper. bash counts
# characters there, not bytes, so Claude's glyphs are not sliced in half -- and it
# forks nothing. This used to pipe every row through perl twice, about 5ms a fork:
# most of a 570ms tick at twenty sessions, all of it paid again on every keypress
# that moved the cursor. (In a non-UTF-8 locale bash counts bytes and a glyph can
# still be cut, which is what the old `cut -c` fallback did anyway.)

term_size() { # -> "rows cols"
  local sz
  sz=$(stty size 2>/dev/null) || sz=""
  case $sz in
    [0-9]*' '[0-9]*) printf '%s' "$sz" ;;
    *) printf '%s %s' "$(tput lines 2>/dev/null || echo 24)" \
                      "$(tput cols  2>/dev/null || echo 80)" ;;
  esac
}

# Width of every column up to and including the cost, which the padding and the
# truncation both have to agree on: 2 + key 1 + 2 + name 23 + 1 + state 9 + 1 +
# agents 3 + 1 + ctx 4 + 1 + cost 8 + 2. Kept in one place because getting it
# wrong by one leaves the highlight bar short of the right edge, which is
# invisible until you look for it.
MON_PREFIX=58

# Where the detail actually starts, which is the same thing plus the account
# column on the screens that have one. The two are separate because the totals
# under the rows hang off the cost column and must not move when a second
# account appears: the account tag sits between the cost and the detail, so
# everything to its left stays where it was.
MON_ACCW=0
MON_DETAIL=$MON_PREFIX

SESSIONS=()
SEL=0          # cursor position in SESSIONS
SEL_NAME=""    # and the session it is on, so it can follow that one as the list moves
STATE_TEXT=""  # set by monitor_state_style
STATE_COLOR=""

# Puts the cursor back on SEL_NAME after the list has been rebuilt. Sessions come
# and go between ticks, and an index alone would slide onto a neighbour.
monitor_sel_sync() {
  local n=${#SESSIONS[@]} i=0
  if [ "$n" -eq 0 ]; then SEL=0; SEL_NAME=""; return; fi
  if [ -n "$SEL_NAME" ]; then
    while [ "$i" -lt "$n" ]; do
      [ "${SESSIONS[$i]}" = "$SEL_NAME" ] && { SEL=$i; return; }
      i=$((i + 1))
    done
  fi
  # Gone, or nothing picked yet: hold the position and adopt whatever is there.
  [ "$SEL" -ge "$n" ] && SEL=$((n - 1))
  [ "$SEL" -lt 0 ] && SEL=0
  SEL_NAME=${SESSIONS[$SEL]}
}

# One totals row -- "total active", then "today", "7d" and the rest -- into
# ROW_OUT, ready to append to the frame. Takes the terminal width rather than
# reading the caller's, since bash would let it and that is exactly the sort of
# thing that breaks quietly when the caller is refactored.
#
# $2 is the word that opens the block, carried by the first row only: the rows
# under it are the same total over a longer reach, so repeating "total" on each
# would be four words of nothing. Every window label is right-aligned to the same
# column whether or not it has that word in front of it, so the labels line up
# and "total" hangs off the left of the first one.
#
# The split goes into fixed-width fields so the rows read as a table instead of
# as four sentences of different lengths. A column with nothing in it is left
# blank rather than zeroed: no api spend and no api sessions look the same from
# here, and neither is worth printing $0.00 for.
ROW_OUT=""
monitor_total_row() {
  local width=$1 mark=$2 lbl=$3 all=$4 sub=$5 api=$6 extra=$7
  local bits sf af ef pad row lead="" text=$lbl
  printf -v sf '%-16s' "${sub:+sub ~\$$sub}"
  printf -v af '%-15s' "${api:+api \$$api}"
  ef=${extra:+extra ~\$$extra}
  bits="  $sf$af$ef"
  while [ -n "$bits" ]; do
    case ${bits: -1} in ' ') bits=${bits%?} ;; *) break ;; esac
  done
  # Cut to what is left of the line, like the detail column above.
  pad=$((width - MON_PREFIX + 2))
  [ ${#bits} -gt "$pad" ] && [ "$pad" -ge 0 ] && bits=${bits:0:$pad}

  # The alignment is worked out here rather than left to a %*s, because the word
  # in front is bold and the label is not: one field cannot hold both, and the
  # escape sequences would be counted as width if it did.
  if [ -n "$mark" ]; then
    text="$mark $lbl"
    lead="${C_BOLD}${mark}${C_RST} "
  fi
  pad=$((MON_PREFIX - 11 - ${#text}))
  [ "$pad" -lt 0 ] && pad=0
  printf -v row '%*s%s%s %s%8s%s%s%s%s' \
    "$pad" '' "$lead" "$lbl" \
    "$C_BOLD" "\$$all" "$C_RST" \
    "$C_DIM" "$bits" "$C_RST"
  ROW_OUT="$row$T_EL"$'\n'
}

# One window of one account -- "  8% to 3:10pm", or "100% FULL to 6:02pm" --
# padded to a fixed width so the two windows line up down the block, and flagged
# when it is exhausted so the caller can color the whole cell without putting an
# escape sequence inside a field printf is padding by bytes.
#
# A window at 100 is FULL, not "nearly there". Tested with -ge rather than =,
# because the figure is not in fact clamped there: readings of 101 have been seen
# in live exports on this machine. The number is printed as it comes, so a window
# past its limit says so rather than being rounded back down to the cap.
ACC_WINW=19
ACC_WIN=""
ACC_WIN_HOT=""
ACC_WIN_KNOWN=""
monitor_acc_window() {
  local lim=$1 rst=$2 t
  ACC_WIN=""; ACC_WIN_HOT=""; ACC_WIN_KNOWN=""
  case $lim in
    ''|-1|*[!0-9]*) printf -v ACC_WIN '%*s' "$ACC_WINW" ''; return 0 ;;
  esac
  ACC_WIN_KNOWN=1
  printf -v t '%3s%%' "$lim"
  if [ "$lim" -ge 100 ] 2>/dev/null; then
    t="$t FULL"
    ACC_WIN_HOT=1
  fi
  [ -n "$rst" ] && t="$t to $rst"
  printf -v ACC_WIN '%-*s' "$ACC_WINW" "$t"
  return 0
}

# One account's line, into ACC_ROW. The address is written out in full here --
# this is the one place on the screen with room for it, and the tags on the rows
# are only readable because this says what they stand for.
#
# Built twice, plain and colored, because the escapes make the string longer than
# it looks and a row that overflows the terminal wraps, which shifts every line
# under it and breaks the redraw. Under the width it is drawn in color; over it,
# the plain one is cut to fit. Both come out of the same fields, so they cannot
# drift apart.
ACC_ROW=""
monitor_acc_row() {
  local width=$1 idx=$2 acct sess plain c5 c7 lead tail tailc
  local w5 h5 k5 w7 h7 k7 p5=5h
  acct=${ACC_KEY[$idx]}
  [ ${#acct} -gt 20 ] && acct=${acct:0:20}
  printf -v sess '%2s sess' "${ACC_N[$idx]}"
  monitor_acc_window "${ACC_LIM5[$idx]}" "${ACC_RST5[$idx]}"
  w5=$ACC_WIN; h5=$ACC_WIN_HOT; k5=$ACC_WIN_KNOWN
  monitor_acc_window "${ACC_LIM7[$idx]}" "${ACC_RST7[$idx]}"
  w7=$ACC_WIN; h7=$ACC_WIN_HOT; k7=$ACC_WIN_KNOWN

  # An account whose only reading has been superseded gets its name and its
  # session count and nothing else -- the line is still worth drawing, since it
  # is how you know the account is there at all, but there is no number to put
  # on it and a blank "5h" would look like one that read zero.
  #
  # The weekly window is last, so an unknown one is dropped outright; the 5-hour
  # one is not, and keeps its width so the weekly stays in its column. Whichever
  # ends the line loses its padding, which is trailing whitespace and nothing
  # else -- the same reason the totals under the rows drop theirs.
  [ -z "$k5" ] && p5='  '
  if [ -n "$k7" ]; then
    while [ -n "$w7" ]; do
      case ${w7: -1} in ' ') w7=${w7%?} ;; *) break ;; esac
    done
  elif [ -n "$k5" ]; then
    while [ -n "$w5" ]; do
      case ${w5: -1} in ' ') w5=${w5%?} ;; *) break ;; esac
    done
  fi

  c5=$C_DIM; c7=$C_DIM
  [ -n "$h5" ] && c5="$C_RED$C_BOLD"
  [ -n "$h7" ] && c7="$C_RED$C_BOLD"
  tail=""; tailc=""
  if [ -n "$k5" ] || [ -n "$k7" ]; then
    tail="  $p5 $w5"
    tailc="  $C_DIM$p5$C_RST $c5$w5$C_RST"
    if [ -n "$k7" ]; then
      tail="$tail  7d $w7"
      tailc="$tailc  ${C_DIM}7d$C_RST $c7$w7$C_RST"
    fi
  fi

  printf -v plain '  %-20s %s%s' "$acct" "$sess" "$tail"
  if [ ${#plain} -gt "$width" ]; then
    ACC_ROW="${plain:0:$width}$T_EL"$'\n'
    return 0
  fi
  printf -v lead '  %-20s ' "$acct"
  ACC_ROW="$lead$C_DIM$sess$C_RST$tailc$T_EL"$'\n'
  return 0
}

ROW_STATE=()   # per session, same order as SESSIONS
ROW_DETAIL=()
X_ATAG=()      # and the account tag its row will carry, blank for no column
N_CLAUDE=0
N_WORK=0
N_NEED=0

# Polls every session and fills the row arrays. This is the expensive half -- one
# list-panes for the lot, then a capture-pane each, about 20ms apiece -- so it
# runs on the refresh tick and not on every keystroke. Moving the cursor cannot
# change any of it, and redrawing from what is already here is what keeps j and k
# instant.
monitor_collect() {
  local i n
  monitor_clock
  monitor_snapshot
  monitor_sel_sync
  monitor_busy_titles
  monitor_read_exports
  monitor_read_ledger

  ROW_STATE=(); ROW_DETAIL=()
  N_CLAUDE=0; N_WORK=0; N_NEED=0
  n=${#SESSIONS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if monitor_read_pane "${P_PANE[$i]}"; then
      monitor_classify "$i"
      monitor_merge "$i"
      monitor_scan_notice
    else
      # The pane went away between the snapshot and the capture.
      CLS_STATE=gone; CLS_DETAIL=""
    fi
    ROW_STATE+=("$CLS_STATE")
    ROW_DETAIL+=("$CLS_DETAIL")
    case $CLS_STATE in
      ask)   N_NEED=$((N_NEED + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      busy)  N_WORK=$((N_WORK + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      draft|idle) N_CLAUDE=$((N_CLAUDE + 1)) ;;
      # No Claude in this pane, so anything left in it -- markers, spend, or the
      # account it was signed in to -- is from one that has since gone: killed
      # before SessionEnd, or the whole tmux server with it.
      *) X_AGENTS[$i]=0; X_ASPEND[$i]=0; X_ACCT[$i]="" ;;
    esac
    # Counted here rather than where the file was read, because only now is it
    # known whether there is still a Claude in the pane. An account whose every
    # session has gone has no line, however recent the export it left behind.
    [ -n "${X_ACCT[$i]}" ] && monitor_acc_find "${X_ACCT[$i]}" &&
      ACC_N[$ACC_I]=$((ACC_N[$ACC_I] + 1))
    X_AGENT_ALL=$((X_AGENT_ALL + ${X_AGENTS[$i]:-0}))
    X_ASPEND_ALL=$((X_ASPEND_ALL + ${X_ASPEND[$i]:-0}))
    i=$((i + 1))
  done

  # The account column earns its place only once there is more than one account
  # to tell apart. On the ordinary single-account screen every row would carry
  # the same word, so there is no column at all and the detail keeps the space.
  monitor_acc_order
  monitor_acc_tags
  X_ATAG=()
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$ACC_TAGGED" -ge 2 ] && [ -n "${X_ACCT[$i]}" ] &&
       monitor_acc_find "${X_ACCT[$i]}"; then
      X_ATAG+=("${ACC_TAG[$ACC_I]}")
    else
      X_ATAG+=("")
    fi
    i=$((i + 1))
  done
}

# Draws what monitor_collect gathered. Talks to tmux not at all, and builds every
# row with printf -v, so a keystroke that only moves the cursor costs a redraw and
# nothing else.
monitor_draw() {
  local h w i n state detail maxd pad row out="" acc="" hdr name ctx cost mark agents tagf tail
  read -r h w <<<"$(term_size)"

  # What every column before the detail takes: two spaces, the key, two spaces,
  # the name at 23, a space, the state at 9, a space, the agent count at 3, a
  # space, the context at 4, a space, the cost at 8, two more spaces -- and then
  # the account tag and two more again, on the screens that show one.
  MON_ACCW=0
  [ "$ACC_TAGGED" -ge 2 ] && MON_ACCW=$((ACC_TAGW + 2))
  MON_DETAIL=$((MON_PREFIX + MON_ACCW))
  maxd=$((w - MON_DETAIL))
  [ "$maxd" -lt 12 ] && maxd=12

  n=${#SESSIONS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    name=${SESSIONS[$i]}
    [ ${#name} -gt 23 ] && name=${name:0:23}
    state=${ROW_STATE[$i]}
    detail=${ROW_DETAIL[$i]}
    [ ${#detail} -gt "$maxd" ] && detail=${detail:0:maxd}
    # Context used, from the status line export. Blank -- not "0%" -- for a
    # session that has not answered yet or has no exporter installed, so an empty
    # column reads as "unknown" rather than "plenty of room left".
    ctx='    '
    case ${X_CTX[$i]} in
      ''|-1|*[!0-9]*) ;;
      *) printf -v ctx '%3s%%' "${X_CTX[$i]}" ;;
    esac
    # Blank, again, rather than $0.00 for a session that has not reported --
    # nothing spent and nothing known are different things.
    printf -v cost '%8s' "${X_COSTF[$i]}"
    # Subagents in flight, "5a". Blank at zero: a bare 0 in every row would be
    # three columns of nothing on a machine that never runs one. The suffix is
    # what makes a small number next to the state read as a count of agents
    # rather than as another percentage, and it is ASCII because printf pads this
    # by bytes.
    agents='   '
    [ "${X_AGENTS[$i]:-0}" -gt 0 ] 2>/dev/null &&
      printf -v agents '%3s' "${X_AGENTS[$i]}a"
    # The account tag, where there is a column for one. Padded here and glued to
    # the front of the detail rather than given a field of its own: it is dim
    # like the detail is, so the two share one run of color, and the escapes stay
    # out of anything printf is padding. Blank for a pane with no Claude in it,
    # which leaves the column empty rather than naming an account that has gone.
    tagf=""
    [ "$MON_ACCW" -gt 0 ] &&
      printf -v tagf '%-*s  ' "$ACC_TAGW" "${X_ATAG[$i]}"
    # Which leaves the tag's padding hanging off the end of a row with no detail
    # on it, so the ordinary row drops it. The cursor's row keeps it: there the
    # padding runs to the right edge anyway, and it is measured from the full
    # width of the column.
    tail="$tagf$detail"
    while [ -n "$tail" ]; do
      case ${tail: -1} in ' ') tail=${tail%?} ;; *) break ;; esac
    done
    monitor_state_style "$state"
    if [ "$i" = "$SEL" ]; then
      # The cursor's row goes in reverse video, with no inner resets -- one would
      # end the highlight halfway across -- and padded out so the bar reaches the
      # right edge (tmux erases in the default attribute, so ESC[K cannot do that
      # for us). The mark is kept as well, so the cursor is still visible with
      # colors off; it and the padding live outside every %-*s, so a multibyte
      # glyph cannot skew them.
      pad=$((w - MON_DETAIL - ${#detail}))
      [ "$pad" -lt 0 ] && pad=0
      printf -v row '%s▸ %s  %-23s %s %s %s %s  %s%s%*s%s' \
        "$C_REV" "${KEYS:$i:1}" \
        "$name" "$STATE_TEXT" "$agents" "$ctx" "$cost" \
        "$tagf" "$detail" "$pad" '' "$C_RST"
    else
      # The agent count is the one column here that is not dim. A fleet running
      # under a session is worth seeing from across the room, and it is the same
      # cyan as "working" because that is what it means.
      printf -v row '  %s%s%s  %-23s %s%s%s %s%s%s %s%s %s%s  %s%s%s' \
        "$C_BOLD" "${KEYS:$i:1}" "$C_RST" \
        "$name" \
        "$STATE_COLOR" "$STATE_TEXT" "$C_RST" \
        "$C_CYA" "$agents" "$C_RST" \
        "$C_DIM" "$ctx" "$cost" "$C_RST" \
        "$C_DIM" "$tail" "$C_RST"
    fi
    # T_EL per row here rather than a sed over the whole block: that was one more
    # fork on the path between a keypress and the screen.
    out+="$row$T_EL"$'\n'
    i=$((i + 1))
  done

  # The totals, one row per window, under the column they total. MON_PREFIX - 11
  # lands each label just left of the cost field, so every figure sits directly
  # beneath the per-session costs above it and beneath each other.
  #
  # "active" is the sessions on screen, and is the only row that can carry
  # "extra": overage is worked out from the live exports, which the ledger, being
  # a record of what was spent rather than of how, does not keep. The rest are
  # the ledger's, and count every session that has run in the window whether or
  # not anything is still up to show for it -- so "active" and "today" overlap,
  # and are meant to.
  if [ "$n" -gt 0 ]; then
    # "total" goes on the first row drawn, whichever that turns out to be: with
    # no live cost to report the block opens on "today" instead, and the word
    # belongs to the block rather than to any one window.
    mark=total
    if [ -n "$X_COST_ALL" ]; then
      monitor_total_row "$w" "$mark" active \
        "$X_COST_ALL" "$X_COST_SUB" "$X_COST_API" "$X_COST_OVER"
      out+="$ROW_OUT"
      mark=""
    fi
    i=0
    while [ "$i" -lt 4 ]; do
      if [ -n "${SPEND_ALL[$i]}" ]; then
        monitor_total_row "$w" "$mark" "${SPEND_LBL[$i]}" \
          "${SPEND_ALL[$i]}" "${SPEND_SUB[$i]}" "${SPEND_API[$i]}" ""
        out+="$ROW_OUT"
        mark=""
      fi
      i=$((i + 1))
    done
  fi

  # The account block, between the header and the rows: one line per account the
  # fleet is signed in to, with that account's own windows on it. Not in the
  # header bar, because there can be more than one of them and the bar is one
  # line; not in a column, because the numbers belong to the account rather than
  # to any session, and a column would repeat each one down every row it owns.
  i=0
  while [ "$i" -lt "$ACC_SHOWN" ]; do
    monitor_acc_row "$w" "${ACC_ORDER[$i]}"
    acc+="$ACC_ROW"
    i=$((i + 1))
  done
  [ -n "$acc" ] && acc+="$T_EL"$'\n'

  if [ "$n" -eq 0 ]; then
    hdr=" MONITOR  no sessions found"
    out="  nothing to monitor yet$T_EL"$'\n'
  else
    printf -v hdr ' MONITOR  %d sessions  %d claude  %d working  %d need you' \
      "$n" "$N_CLAUDE" "$N_WORK" "$N_NEED"
    # Only when there are any. Unlike the counts before it, this one is about
    # work the fleet is doing rather than about the sessions themselves, and a
    # standing "0 agents" would be a word about nothing on most machines.
    #
    # The money the agents have accounted for rides next to the count when there
    # is one, and stands on its own when there is not -- a fleet that finished an
    # hour ago has spent something and has nothing in flight, and that is exactly
    # when the figure is worth reading. Worded on its own so it cannot be taken
    # for another window's total: it is a share of the costs below, not a sum to
    # add to them.
    if [ "$X_AGENT_ALL" -gt 0 ] 2>/dev/null; then
      hdr="$hdr  $X_AGENT_ALL agents"
      [ "$X_ASPEND_ALL" -gt 0 ] 2>/dev/null &&
        printf -v hdr '%s $%d.%02d' "$hdr" \
          $((X_ASPEND_ALL / 100)) $((X_ASPEND_ALL % 100))
    elif [ "$X_ASPEND_ALL" -gt 0 ] 2>/dev/null; then
      printf -v hdr '%s  $%d.%02d in agents' "$hdr" \
        $((X_ASPEND_ALL / 100)) $((X_ASPEND_ALL % 100))
    fi
    hdr="$hdr  refresh ${INTERVAL}s"
    # The limits go in the block under the header, not up here -- there can be
    # more than one account's worth of them and this is one line. What is left
    # here is the fallback: a fleet where nothing named an account, which is what
    # a Claude older than the acct= export looks like, keeps the pair it always
    # had in the place it always had it.
    #
    # Kept to ASCII -- printf pads this bar by bytes, so a multibyte glyph would
    # leave the reverse video short of the right edge.
    # A window reading 100 is FULL, not "nearly there": the utilization behind it
    # is clamped, so it cannot climb past that to say how far past it went.
    if [ "$ACC_SHOWN" -eq 0 ]; then
      if [ -n "$X_LIM5" ]; then
        hdr="$hdr  5h ${X_LIM5}%"
        [ "$X_LIM5" -ge 100 ] 2>/dev/null && hdr="$hdr FULL"
        [ -n "$X_RST5" ] && hdr="$hdr to $X_RST5"
      fi
      if [ -n "$X_LIM7" ]; then
        hdr="$hdr  7d ${X_LIM7}%"
        [ "$X_LIM7" -ge 100 ] 2>/dev/null && hdr="$hdr FULL"
        [ -n "$X_RST7" ] && hdr="$hdr to $X_RST7"
      fi
    fi
    # Spend is not up here any more; it is on the total line under the rows,
    # beneath the per-session column it adds up.
    [ -n "$X_NOTICE" ] && hdr="$hdr  ** $X_NOTICE"
  fi

  # Redraw in place: home the cursor and erase line by line. A full clear each
  # tick flickers.
  { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" "${hdr:0:$w}" "$C_RST" "$T_EL"
    printf '%s\n' "$T_EL"
    printf '%s' "$acc"
    printf '%s' "$out"
    printf '%s\n' "$T_EL"
    printf '%s  %sj/k%s move   %senter%s jump   %s1-9/a-z%s jump directly   %sr%s refresh   %sq%s quit%s%s\n' \
      "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST" "$T_EL"
    printf '%s' "$T_ED"
  } 2>/dev/null
}

# --- keys -------------------------------------------------------------------

# Switch the client that is looking at this session over to a target session.
#
# The client has to be resolved explicitly: a bare `switch-client -t` picks an
# arbitrary client when it has no context, which means it can yank a client
# attached to a completely unrelated session. So if we cannot identify the client
# for our own session, we do nothing rather than move someone else's view.
monitor_switch() {
  local target=$1 sess client
  [ -n "${TMUX:-}" ] || return 1
  client=$(tmux display-message -p '#{client_name}' 2>/dev/null)
  if [ -z "$client" ]; then
    sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    [ -n "$sess" ] || return 1
    client=$(tmux list-clients -t "$sess" -F '#{client_name}' 2>/dev/null | head -1)
  fi
  [ -n "$client" ] || return 1
  tmux switch-client -c "$client" -t "$target" 2>/dev/null
}

key_index() { # position of $1 in KEYS, or -1
  local i=0 c
  while [ "$i" -lt ${#KEYS} ]; do
    c=${KEYS:$i:1}
    [ "$c" = "$1" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# One keypress, waiting $1 seconds for it, with the arrow keys reported as the
# hjkl they stand in for. Without that an arrow would read as a bare esc and quit
# the monitor. The fractional timeout is what distinguishes "esc alone" from "esc
# starting a sequence"; bash 3.2 rejects it, and there an arrow quits.
monitor_key() {
  local k rest t=$1
  IFS= read -rsn1 -t "$t" k || return 1
  if [ "$k" = $'\033' ]; then
    IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=""
    case $rest in
      '[A') k=k ;;
      '[B') k=j ;;
      '[C') k=l ;;
      '[D') k=h ;;
      *)    k=$'\033' ;;
    esac
  fi
  printf '%s' "$k"
}

# `read -s` only silences the keys it reads itself, so anything typed while a tick
# is being drawn is echoed by the terminal -- holding j paints "jjjjj" over the
# monitor. Echo goes off for as long as the monitor is up instead, and the
# terminal is put back exactly as it was on the way out. SAVED_STTY is global on
# purpose: the trap runs after run_monitor's locals are gone.
SAVED_STTY=""

monitor_raw_off() {
  printf '%s%s' "$T_SHOW" "$T_ALT_OFF"
  [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
  SAVED_STTY=""
}

run_monitor() {
  local key idx n leave moved
  printf '%s%s' "$T_ALT_ON" "$T_HIDE"
  trap 'monitor_raw_off; exit 0' EXIT INT TERM
  if [ -t 0 ]; then
    SAVED_STTY=$(stty -g 2>/dev/null) || SAVED_STTY=""
    stty -echo 2>/dev/null || true
  fi

  monitor_collect
  while :; do
    monitor_draw
    if [ ! -t 0 ]; then
      sleep "$INTERVAL"   # no keyboard (piped/headless): just keep refreshing
      monitor_collect
      continue
    fi

    if key=$(monitor_key "$INTERVAL"); then
      n=${#SESSIONS[@]}
      leave=""
      moved=""
      # Held keys arrive faster than the screen can be drawn, so everything
      # already queued is applied before drawing again. Otherwise the cursor
      # crawls behind the keyboard and keeps moving after the key comes up.
      while :; do
        case $key in
          q|$'\033') leave=1 ;;
          r) ;;     # nothing to do: the collect below is the refresh
          '') [ "$n" -gt 0 ] && monitor_switch "${SESSIONS[$SEL]}" ;;
          j) moved=1; [ "$n" -gt 0 ] && { SEL=$(( (SEL + 1) % n )); SEL_NAME=${SESSIONS[$SEL]}; } ;;
          k) moved=1; [ "$n" -gt 0 ] && { SEL=$(( (SEL - 1 + n) % n )); SEL_NAME=${SESSIONS[$SEL]}; } ;;
          h|l) moved=1 ;;   # one column, so there is nowhere sideways to go
          *)
            idx=$(key_index "$key")
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
              monitor_switch "${SESSIONS[$idx]}"
            fi
            ;;
        esac
        [ -n "$leave" ] && break
        key=$(monitor_key 0.001) || break
      done
      [ -n "$leave" ] && break
      # A cursor move redraws from what the last tick collected; anything else
      # goes and looks again.
      [ -n "$moved" ] || monitor_collect
    else
      monitor_collect   # the interval ran out: time for a fresh tick
    fi
  done
}

open_session() {
  if ! tmux has-session -t "$MON" 2>/dev/null; then
    tmux new-session -d -s "$MON" -n monitor "$(printf '%q --run' "$SELF")" || return 1
    tmux set-option -t "$MON" status-left \
      '#[fg=#1F1F28,bg=#E6C384,bold] monitor #[default]'
    tmux set-option -t "$MON" remain-on-exit off
    tmux set-option -w -t "$MON:monitor" automatic-rename off
  fi
  # Same explicit client resolution as the jump keys: prefix+M arrives via
  # run-shell, where a bare switch-client has to guess the client.
  if [ -n "${TMUX:-}" ]; then
    monitor_switch "$MON"
  else
    tmux attach-session -t "$MON"
  fi
}

# Guarded so the file can be sourced for its functions -- which the tests do, to
# reach the ledger arithmetic without a terminal. Run normally, this is the only
# thing that happens.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    --run)      run_monitor ;;
    ''|--open)  open_session ;;
    *)
      printf 'usage: %s [--open|--run]\n' "$(basename "$0")" >&2
      exit 2
      ;;
  esac
fi
