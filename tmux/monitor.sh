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
# window to report on: a window actually running Claude, else one named
# $MONITOR_WINDOW, else the session's active window.
#
# Tunables: MONITOR_INTERVAL (seconds, default 2), MONITOR_WINDOW (preferred
# window name, default "claude"), MONITOR_FILTER (regex; only sessions matching
# it are listed, default all), MONITOR_SESSION (default "monitor").
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

MON=${MONITOR_SESSION:-monitor}
INTERVAL=${MONITOR_INTERVAL:-2}
MONITOR_WINDOW=${MONITOR_WINDOW:-claude}
MONITOR_FILTER=${MONITOR_FILTER:-}

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

# --- sessions ---------------------------------------------------------------

# Sessions to list, alphabetical, the monitor itself excluded.
monitor_sessions() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null |
    grep -vx "$MON" |
    { if [ -n "$MONITOR_FILTER" ]; then grep -E "$MONITOR_FILTER"; else cat; fi } |
    sort
}

# Claude Code reports its version as the process name ("2.1.222"), so treat a
# bare version and anything containing "claude" as Claude.
is_claude_cmd() {
  case $1 in
    *claude*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Window of a session to report on -> "window_id|pane_current_command".
# Prefers the window actually running Claude over the one merely named for it:
# the running process is the truth, and automatic-rename means the name often
# is not "claude" at all.
monitor_pick_window() {
  local sess=$1 name id cmd act named="" claude="" active=""
  while IFS='|' read -r name id cmd act; do
    [ -n "$id" ] || continue
    if [ -z "$claude" ] && is_claude_cmd "$cmd"; then claude="$id|$cmd"; fi
    if [ -z "$named" ] && [ "$name" = "$MONITOR_WINDOW" ]; then named="$id|$cmd"; fi
    if [ "$act" = 1 ]; then active="$id|$cmd"; fi
  done < <(tmux list-windows -t "$sess" \
             -F '#{window_name}|#{window_id}|#{pane_current_command}|#{window_active}' 2>/dev/null)
  printf '%s' "${claude:-${named:-$active}}"
}

# Visible text of a window's active pane, no escape sequences.
monitor_capture() { tmux capture-pane -p -t "$1" 2>/dev/null; }

# Seconds since that window last had output.
monitor_age() {
  local a now
  a=$(tmux display-message -p -t "$1" '#{window_activity}' 2>/dev/null) || return
  [ -n "$a" ] || return
  now=$(date +%s)
  printf '%s' "$((now - a))"
}

# 95 -> 1m, 4210 -> 1h10m, 1050480 -> 12d3h
monitor_ago() {
  local s=${1:-} m h d
  case $s in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"; return; fi
  m=$((s / 60))
  if [ "$m" -lt 60 ]; then printf '%dm' "$m"; return; fi
  h=$((m / 60))
  if [ "$h" -lt 24 ]; then printf '%dh%dm' "$h" "$((m % 60))"; return; fi
  d=$((h / 24)); printf '%dd%dh' "$d" "$((h % 24))"
}

# --- state ------------------------------------------------------------------

# Braille frames Claude spins in the pane title while it works. Only used when
# perl is missing: the perl check below covers the whole braille block, so it
# survives Claude picking frames that are not in this list.
BRAILLE_FRAMES='⠁⠂⠄⠈⠐⠠⡀⢀⠃⠆⠇⠋⠏⠙⠘⠸⠴⠦⠧⠹⠼⣀⣤⣶⣿'

monitor_title() { tmux display-message -p -t "$1" '#{pane_title}' 2>/dev/null; }

# True when a window's title says Claude is working. Claude sets the title to
# "<braille frame> <task summary>" for the whole turn and swaps the frame for
# "✳" the moment it stops, so the leading glyph is the signal. Anything else --
# "✳ Claude Code", a bare hostname, an empty title -- is not working.
monitor_title_busy() {
  local t
  [ -n "${1:-}" ] || return 1
  t=$(monitor_title "$1") || return 1
  [ -n "$t" ] || return 1
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$t" |
      perl -CS -ne 'exit(ord(substr($_, 0, 1)) >= 0x2800 &&
                         ord(substr($_, 0, 1)) <= 0x28FF ? 0 : 1)'
    return
  fi
  case $BRAILLE_FRAMES in *"$(printf '%s' "$t" | head -c 3)"*) return 0 ;; esac
  return 1
}

# monitor_classify <pane_current_command> <pane text> [window id] -> "state|detail"
#
#   ask     Claude is waiting on a permission / plan prompt  (actionable)
#   busy    Claude is generating
#   draft   text sitting in the prompt, unsent  (also actionable)
#   idle    Claude is up with an empty prompt
#   shell   just a shell
#   other   something else running (detail says what)
#   gone    session or window disappeared
#
# The patterns below are Claude Code UI strings, kept here (and in
# monitor_title_busy) on purpose: if a future version reworks its footer or its
# title, those two are the only places to fix.
monitor_classify() {
  local cmd=$1 text=$2 wid=${3:-} detail

  [ -n "$cmd" ] || { printf 'gone|'; return; }
  case $cmd in
    zsh|-zsh|bash|-bash|sh|fish|login) printf 'shell|'; return ;;
  esac
  is_claude_cmd "$cmd" || { printf 'other|%s' "$cmd"; return; }

  # Actionable prompts win: a pending question matters more than the spinner.
  # The last pattern is the first-run folder-trust prompt, which asks with none
  # of the usual wording.
  local asks='Do you want|Would you like|Ready to code\?|Is this a project you created'
  if printf '%s\n' "$text" | grep -qE "$asks"; then
    detail=$(printf '%s\n' "$text" |
      grep -E "$asks" |
      tail -1 |
      sed -e 's/^[^[:alnum:]]*//' -e 's/[[:space:]]*$//')
    printf 'ask|%s' "$detail"
    return
  fi

  # Working. Claude's own footer hint ("esc to interrupt") is gone as of 2.1.x,
  # and the status line ("✢ Musing… (7s · thinking)") only shows before the
  # reply starts streaming -- so the title is what actually spans the turn.
  # Both text forms are still checked: they cost one grep and cover versions
  # that do not set a title.
  if monitor_title_busy "$wid" ||
     printf '%s\n' "$text" | grep -qE 'esc to interrupt|\([0-9]+s · '; then
    # "✻ Cooking… (esc to interrupt · ctrl+t to hide todos)" -> "Cooking…"
    # "✢ Musing… (7s · ↓ 481 tokens · thinking)"            -> "Musing…"
    detail=$(printf '%s\n' "$text" |
      grep -E 'esc to interrupt|\([0-9]+s · ' |
      tail -1 |
      sed -e 's/(esc to interrupt.*//' -e 's/([0-9]*s · .*//' \
          -e 's/^[^[:alnum:]]*//' -e 's/[[:space:]]*$//')
    # No status line on screen: fall back to the title's task summary. "Claude
    # Code" is the placeholder title of a turn too young to have a summary yet,
    # so it says nothing worth a column.
    if [ -z "$detail" ] && [ -n "$wid" ]; then
      detail=$(monitor_title "$wid" | sed -e 's/^[^ ]* //' -e 's/[[:space:]]*$//')
      [ "$detail" = 'Claude Code' ] && detail=
    fi
    printf 'busy|%s' "$detail"
    return
  fi

  # Nothing running. The last prompt line tells us whether something is typed
  # but unsent -- worth surfacing, since that one is waiting on a keystroke.
  # (Earlier lines starting with the prompt glyph are scrollback, so take the
  # last one: the input box is always at the bottom.)
  local prompt agents
  prompt=$(printf '%s\n' "$text" | grep '^❯' | tail -1 | sed -e 's/^❯[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "$prompt" ]; then
    printf 'draft|%s' "$prompt"
    return
  fi

  # The "N agents" footer counter stays on screen while Claude sits idle, so it
  # is a detail, not a state: background agents may still be running.
  agents=$(printf '%s\n' "$text" | grep -oE '[0-9]+ agents?' | tail -1)
  printf 'idle|%s' "$agents"
}

# State of a session -> "window_id|state|detail". The free-text detail goes last
# so that a prompt containing "|" cannot shift the other fields when read splits
# on it (the final variable of a `read` gets the unsplit remainder).
monitor_state() {
  local sess=$1 pick id cmd
  pick=$(monitor_pick_window "$sess")
  if [ -z "$pick" ]; then printf '|gone|'; return; fi
  id=${pick%%|*}
  cmd=${pick#*|}
  printf '%s|%s' "$id" "$(monitor_classify "$cmd" "$(monitor_capture "$id")" "$id")"
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

ROW_STATE=()   # per session, same order as SESSIONS
ROW_DETAIL=()
ROW_AGE=()
N_CLAUDE=0
N_WORK=0
N_NEED=0

# Polls every session and fills the row arrays. This is the expensive half -- a
# capture-pane and a couple of display-messages per session, about 25ms each --
# so it runs on the refresh tick and not on every keystroke. Moving the cursor
# cannot change any of it, and redrawing from what is already here is what keeps
# j and k instant.
monitor_collect() {
  local sess wid state detail
  SESSIONS=()
  while IFS= read -r sess; do SESSIONS+=("$sess"); done < <(monitor_sessions)
  monitor_sel_sync

  ROW_STATE=(); ROW_DETAIL=(); ROW_AGE=()
  N_CLAUDE=0; N_WORK=0; N_NEED=0
  for sess in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
    IFS='|' read -r wid state detail <<<"$(monitor_state "$sess")"
    ROW_STATE+=("$state")
    ROW_DETAIL+=("$detail")
    ROW_AGE+=("$(monitor_ago "$(monitor_age "${wid:-$sess}")")")
    case $state in
      ask)   N_NEED=$((N_NEED + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      busy)  N_WORK=$((N_WORK + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      draft|idle) N_CLAUDE=$((N_CLAUDE + 1)) ;;
    esac
  done
}

# Draws what monitor_collect gathered. Talks to tmux not at all, and builds every
# row with printf -v, so a keystroke that only moves the cursor costs a redraw and
# nothing else.
monitor_draw() {
  local h w i n state detail age maxd pad row out="" hdr name
  read -r h w <<<"$(term_size)"

  maxd=$((w - 50))
  [ "$maxd" -lt 12 ] && maxd=12

  n=${#SESSIONS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    name=${SESSIONS[$i]}
    [ ${#name} -gt 23 ] && name=${name:0:23}
    state=${ROW_STATE[$i]}
    detail=${ROW_DETAIL[$i]}
    [ ${#detail} -gt "$maxd" ] && detail=${detail:0:maxd}
    age=${ROW_AGE[$i]}
    monitor_state_style "$state"
    if [ "$i" = "$SEL" ]; then
      # The cursor's row goes in reverse video, with no inner resets -- one would
      # end the highlight halfway across -- and padded out so the bar reaches the
      # right edge (tmux erases in the default attribute, so ESC[K cannot do that
      # for us). The 47 is what the columns before the detail take: mark, key,
      # name, state and age with their gaps. The mark is kept as well, so the
      # cursor is still visible with colors off; it and the padding live outside
      # every %-*s, so a multibyte glyph cannot skew them.
      pad=$((w - 47 - ${#detail}))
      [ "$pad" -lt 0 ] && pad=0
      printf -v row '%s▸ %s  %-23s %s  %5s  %s%*s%s' \
        "$C_REV" "${KEYS:$i:1}" \
        "$name" "$STATE_TEXT" "$age" \
        "$detail" "$pad" '' "$C_RST"
    else
      printf -v row '  %s%s%s  %-23s %s%s%s  %5s  %s%s%s' \
        "$C_BOLD" "${KEYS:$i:1}" "$C_RST" \
        "$name" \
        "$STATE_COLOR" "$STATE_TEXT" "$C_RST" \
        "$age" \
        "$C_DIM" "$detail" "$C_RST"
    fi
    # T_EL per row here rather than a sed over the whole block: that was one more
    # fork on the path between a keypress and the screen.
    out+="$row$T_EL"$'\n'
    i=$((i + 1))
  done

  if [ "$n" -eq 0 ]; then
    hdr=" MONITOR  no sessions found"
    out="  nothing to monitor yet$T_EL"$'\n'
  else
    printf -v hdr ' MONITOR  %d sessions  %d claude  %d working  %d need you  refresh %ss' \
      "$n" "$N_CLAUDE" "$N_WORK" "$N_NEED" "$INTERVAL"
  fi

  # Redraw in place: home the cursor and erase line by line. A full clear each
  # tick flickers.
  { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" "${hdr:0:$w}" "$C_RST" "$T_EL"
    printf '%s\n' "$T_EL"
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

case ${1:-} in
  --run)      run_monitor ;;
  ''|--open)  open_session ;;
  *)
    printf 'usage: %s [--open|--run]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
