#!/usr/bin/env bash
# Monitor for every tmux session: one line each, showing what its Claude window
# is doing, plus a key to jump straight to the one that wants you.
#
#   monitor.sh          open the monitor session (reuses it if up)
#   monitor.sh --run    run the monitor here, in the current pane
#
# Bound to prefix+M in .tmux.conf.
#
# Keys: 1-9/a-p jump to that session, r refresh now, q quit.
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
# left out on purpose -- they are quit and refresh.
KEYS="123456789abcdefghijklmnop"

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

# monitor_classify <pane_current_command> <pane text>  ->  "state|detail"
#
#   ask     Claude is waiting on a permission / plan prompt  (actionable)
#   busy    Claude is generating
#   draft   text sitting in the prompt, unsent  (also actionable)
#   idle    Claude is up with an empty prompt
#   shell   just a shell
#   other   something else running (detail says what)
#   gone    session or window disappeared
#
# The patterns below are Claude Code UI strings, kept in this one function on
# purpose: if a future version reworks its footer, this is the only place to fix.
monitor_classify() {
  local cmd=$1 text=$2 detail

  [ -n "$cmd" ] || { printf 'gone|'; return; }
  case $cmd in
    zsh|-zsh|bash|-bash|sh|fish|login) printf 'shell|'; return ;;
  esac
  is_claude_cmd "$cmd" || { printf 'other|%s' "$cmd"; return; }

  # Actionable prompts win: a pending question matters more than the spinner.
  if printf '%s\n' "$text" | grep -qE 'Do you want|Would you like|Ready to code\?'; then
    detail=$(printf '%s\n' "$text" |
      grep -E 'Do you want|Would you like|Ready to code\?' |
      tail -1 |
      sed -e 's/^[^[:alnum:]]*//' -e 's/[[:space:]]*$//')
    printf 'ask|%s' "$detail"
    return
  fi

  if printf '%s\n' "$text" | grep -qF 'esc to interrupt'; then
    # "✻ Cooking… (esc to interrupt · ctrl+t to hide todos)" -> "Cooking…"
    detail=$(printf '%s\n' "$text" |
      grep -F 'esc to interrupt' |
      tail -1 |
      sed -e 's/(esc to interrupt.*//' -e 's/^[^[:alnum:]]*//' -e 's/[[:space:]]*$//')
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
  printf '%s|%s' "$id" "$(monitor_classify "$cmd" "$(monitor_capture "$id")")"
}

# State -> fixed-width label + color. ASCII on purpose: printf pads by bytes, so
# a multibyte glyph here would break column alignment.
monitor_state_label() {
  case $1 in
    ask)   printf '%s' "${C_BOLD}${C_YEL}NEEDS YOU${C_RST}" ;;
    busy)  printf '%s' "${C_CYA}working  ${C_RST}" ;;
    draft) printf '%s' "${C_YEL}draft    ${C_RST}" ;;
    idle)  printf '%s' "${C_GRN}idle     ${C_RST}" ;;
    shell) printf '%s' "${C_DIM}shell    ${C_RST}" ;;
    other) printf '%s' "${C_DIM}other    ${C_RST}" ;;
    gone)  printf '%s' "${C_RED}gone     ${C_RST}" ;;
    *)     printf '%s' "${C_DIM}?        ${C_RST}" ;;
  esac
}

# --- rendering --------------------------------------------------------------

# Truncate each line of stdin to $1 columns. BSD `cut -c` counts bytes, which
# would slice Claude's glyphs in half, so prefer perl. (Counts characters, not
# display width, so double-width glyphs can still overhang by a column or two.)
monitor_trunc() {
  local w=$1
  [ "$w" -gt 0 ] 2>/dev/null || w=80
  if command -v perl >/dev/null 2>&1; then
    perl -CS -ne 'chomp; print substr($_, 0, '"$w"'), "\n"'
  else
    cut -c "1-$w"
  fi
}

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

render() {
  local h w sess wid state detail age i=0 need=0 work=0 claude=0 maxd out hdr name
  read -r h w <<<"$(term_size)"

  SESSIONS=()
  while IFS= read -r sess; do SESSIONS+=("$sess"); done < <(monitor_sessions)

  maxd=$((w - 50))
  [ "$maxd" -lt 12 ] && maxd=12

  out=""
  for sess in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
    IFS='|' read -r wid state detail <<<"$(monitor_state "$sess")"
    age=$(monitor_ago "$(monitor_age "${wid:-$sess}")")
    case $state in
      ask)   need=$((need + 1)); claude=$((claude + 1)) ;;
      busy)  work=$((work + 1)); claude=$((claude + 1)) ;;
      draft|idle) claude=$((claude + 1)) ;;
    esac
    [ -n "$detail" ] && detail=$(printf '%s' "$detail" | monitor_trunc "$maxd")
    name=$(printf '%s' "$sess" | monitor_trunc 23)
    out+=$(printf '  %s%s%s  %-23s %s  %5s  %s%s%s' \
      "$C_BOLD" "${KEYS:$i:1}" "$C_RST" \
      "$name" \
      "$(monitor_state_label "$state")" \
      "$age" \
      "$C_DIM" "$detail" "$C_RST")
    out+=$'\n'
    i=$((i + 1))
  done

  if [ "$i" -eq 0 ]; then
    hdr=" MONITOR  no sessions found"
    out="  nothing to monitor yet"$'\n'
  else
    hdr=$(printf ' MONITOR  %d sessions  %d claude  %d working  %d need you  refresh %ss' \
      "$i" "$claude" "$work" "$need" "$INTERVAL")
  fi

  # Redraw in place: home the cursor and erase line by line. A full clear each
  # tick flickers.
  { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" "${hdr:0:$w}" "$C_RST" "$T_EL"
    printf '%s\n' "$T_EL"
    printf '%s' "$out" | sed "s/\$/${T_EL}/"
    printf '%s\n' "$T_EL"
    printf '%s  %s1-9/a-p%s jump   %sr%s refresh   %sq%s quit%s%s\n' \
      "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
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

run_monitor() {
  local key idx
  printf '%s%s' "$T_ALT_ON" "$T_HIDE"
  trap 'printf "%s%s" "$T_SHOW" "$T_ALT_OFF"; exit 0' EXIT INT TERM

  while :; do
    render
    if [ -t 0 ]; then
      if IFS= read -rsn1 -t "$INTERVAL" key; then
        case $key in
          q) break ;;
          r|'') continue ;;
          *)
            idx=$(key_index "$key")
            if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#SESSIONS[@]} ]; then
              monitor_switch "${SESSIONS[$idx]}"
            fi
            ;;
        esac
      fi
    else
      sleep "$INTERVAL"   # no keyboard (piped/headless): just keep refreshing
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
