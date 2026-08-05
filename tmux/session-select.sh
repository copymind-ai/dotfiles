#!/usr/bin/env bash
# Session picker: one line per session, each with a jump key -- digits 1-9
# first, then a-z -- so switching is always a single keystroke.
#
#   session-select.sh          open the picker in a popup (bound to prefix+S)
#   session-select.sh --run    draw the picker here, in the current pane
#
# Replaces tmux's own choose-session, whose labels start at 0 and switch to M-a
# from the tenth entry on, and are not configurable.
#
# Keys: 1-9 then a-z switch to that session, esc or enter cancel. h, j, k and l
# are skipped: they are the pane navigation keys, and reaching for one here
# should do nothing rather than fling you into an unrelated session.
#
# Tunables: PICKER_FILTER (regex; only sessions matching it are listed, default
# all), PICKER_WIDTH (popup width, default 56), PICKER_COLW (width of one column
# once the list needs more than one, default 30).
#
# PICKER_CLIENT, PICKER_COLS, PICKER_ROWS and PICKER_CHROME are handed to --run
# by the popup that sized it; they are not meant to be set by hand.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

FILTER=${PICKER_FILTER:-}
WIDTH=${PICKER_WIDTH:-56}
COLW=${PICKER_COLW:-30}
COLW_MIN=22   # narrowest a column may get before another one is out of the question

# Digits first -- they match the muscle memory of window indices -- then the
# alphabet less hjkl, which stay pane navigation. 31 keys in total; anything past
# that is listed without one.
KEYS="123456789abcdefgimnopqrstuvwxyz"

if [ -t 1 ] || [ -n "${PICKER_FORCE_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
else
  C_RST=; C_BOLD=; C_DIM=; C_REV=; C_GRN=; C_YEL=
fi

# --- sessions ---------------------------------------------------------------

# "windows|attached|name", alphabetical by name -- the same order as
# `choose-session -O name`. The name goes last because it is the one field that
# may contain "|": as the final variable of a `read` it gets the unsplit
# remainder, so it cannot shift the others.
picker_sessions() {
  tmux list-sessions \
      -F '#{session_windows}|#{?session_attached,attached,}|#{session_name}' \
      2>/dev/null |
    { if [ -n "$FILTER" ]; then grep -E "$FILTER"; else cat; fi } |
    LC_ALL=C sort -t'|' -k3,3
}

# Client this picker acts on. The key binding passes it in as PICKER_CLIENT --
# run-shell expands #{client_name} for the client that pressed the key, which is
# the only reliable answer -- and the popup forwards it on. This fallback is for
# running the script by hand.
#
# The client has to be named explicitly on switch-client: a bare `-t` picks an
# arbitrary client when it has no context, which can yank a client attached to
# an unrelated session.
picker_client() {
  local sess client
  client=$(tmux display-message -p '#{client_name}' 2>/dev/null)
  if [ -z "$client" ]; then
    sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    [ -n "$sess" ] || return 1
    client=$(tmux list-clients -t "$sess" -F '#{client_name}' 2>/dev/null | head -1)
  fi
  [ -n "$client" ] || return 1
  printf '%s' "$client"
}

picker_switch() {
  local target=$1 client=${PICKER_CLIENT:-}
  [ -n "$client" ] || client=$(picker_client) || return 1
  tmux switch-client -c "$client" -t "$target" 2>/dev/null
}

# --- rendering --------------------------------------------------------------

# Truncate each line of stdin to $1 columns. BSD `cut -c` counts bytes, which
# would slice a multibyte session name in half, so prefer perl.
picker_trunc() {
  local w=$1
  [ "$w" -gt 0 ] 2>/dev/null || w=40
  if command -v perl >/dev/null 2>&1; then
    perl -CS -ne 'chomp; print substr($_, 0, '"$w"'), "\n"'
  else
    cut -c "1-$w"
  fi
}

SESSIONS=()

# Draws the list and fills SESSIONS, so that the key read afterwards can index
# straight into it.
#
# $3 columns, filled top to bottom and then left to right, so the keys read in
# order. More than one column is how a list too tall for the client still shows
# every entry -- letting it scroll would take the header and the first keys off
# the top, which are the ones you reach for most. $4 = 0 drops the header and
# footer too, for a client so short that even the columns do not fit.
render() {
  local cur=$1 w=$2 cols=$3 chrome=${4:-1} maxrows=${5:-0}
  local colw nw wins att name key mark i n rows shown r c idx line out=""
  local -a cells=()

  [ "$cols" -ge 1 ] 2>/dev/null || cols=1
  colw=$((w / cols))
  nw=$((colw - 10))
  [ "$nw" -lt 8 ] && nw=8

  SESSIONS=()
  i=0
  while IFS='|' read -r wins att name; do
    [ -n "$name" ] || continue
    SESSIONS+=("$name")
    key=${KEYS:$i:1}
    [ -n "$key" ] || key=' '   # past the last key: still listed, just not jumpable
    # The session this client is on is marked, not hidden, so the keys stay put
    # no matter which session you press prefix+S from.
    if [ "$name" = "$cur" ]; then mark="*"
    elif [ -n "$att" ]; then mark="+"
    else mark=" "; fi
    # Only the name is padded to width -- the colors around it are zero-width,
    # but printf counts bytes, so they must stay outside any %-*s.
    cells+=("$(printf '  %s%s%s %s%s%s%-*s%s  %s%2sw%s' \
      "$C_BOLD" "$key" "$C_RST" \
      "$C_YEL" "$mark" "$C_RST" \
      "$nw" "$(printf '%s' "$name" | picker_trunc "$nw")" "$C_RST" \
      "$C_DIM" "$wins" "$C_RST")")
    i=$((i + 1))
  done < <(picker_sessions)

  n=$i
  rows=$(( (n + cols - 1) / cols ))
  [ "$rows" -lt 1 ] && rows=1
  # More entries than the popup has room for: spend the last visible cell on
  # saying so, rather than dropping the tail silently.
  if [ "$maxrows" -gt 0 ] && [ "$rows" -gt "$maxrows" ]; then
    rows=$maxrows
    shown=$((cols * rows))
    if [ "$shown" -lt "$n" ] && [ "$shown" -gt 0 ]; then
      cells[$((shown - 1))]=$(printf '  %s... %d more%s' \
        "$C_DIM" "$((n - shown + 1))" "$C_RST")
    fi
  fi
  for (( r = 0; r < rows; r++ )); do
    line=""
    for (( c = 0; c < cols; c++ )); do
      idx=$(( c * rows + r ))
      [ "$idx" -lt "$n" ] && line+="${cells[$idx]}"
    done
    out+="$line"$'\n'
  done

  # The last line carries no newline: the popup is sized to fit exactly, and one
  # more would scroll the top off.
  { printf '\033[H'
    if [ "$chrome" = 1 ]; then
      printf '%s%-*s%s\n\n' "${C_REV}${C_BOLD}" "$w" \
        "$(printf ' SESSIONS  %d' "$n")" "$C_RST"
      printf '%s' "$out"
      printf '\n%s  %s1-9/a-z%s (not hjkl)  %sesc%s cancel  %s*%s here  %s+%s attached%s' \
        "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
        "$C_RST$C_YEL" "$C_RST$C_DIM" "$C_RST$C_YEL" "$C_RST$C_DIM" "$C_RST"
    else
      printf '%s' "${out%$'\n'}"
    fi
    printf '\033[J'
  } 2>/dev/null
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

term_cols() {
  local sz
  sz=$(stty size 2>/dev/null) || sz=""
  case $sz in
    [0-9]*' '[0-9]*) printf '%s' "${sz#* }" ;;
    *) printf '%s' "$(tput cols 2>/dev/null || echo 56)" ;;
  esac
}

run_picker() {
  local cur key idx
  # #{client_session}, not #{session_name}: outside a pane the latter reports
  # whichever session was last active, which is not necessarily ours.
  cur=$(tmux display-message ${PICKER_CLIENT:+-c "$PICKER_CLIENT"} \
          -p '#{client_session}' 2>/dev/null)
  # The layout comes from whoever sized the popup, so it matches the box it was
  # given.
  render "$cur" "$(term_cols)" "${PICKER_COLS:-1}" "${PICKER_CHROME:-1}" \
         "${PICKER_ROWS:-0}"
  [ ${#SESSIONS[@]} -gt 0 ] || return 0
  [ -t 0 ] || return 0

  IFS= read -rsn1 key || return 0
  case $key in
    ''|$'\033') ;;              # enter, esc: just close
    *)
      idx=$(key_index "$key")
      if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#SESSIONS[@]} ]; then
        picker_switch "${SESSIONS[$idx]}"
      fi
      ;;
  esac
  # Always succeed: run-shell prints "returned 1" over the client's pane if the
  # popup's command fails, and cancelling is not a failure.
  return 0
}

# --- popup ------------------------------------------------------------------

# Columns and rows for $1 entries in $2 usable rows on a $3-column client, as
# "cols rows". Up to three columns, and only as many as the client can hold at
# COLW_MIN each.
picker_fit() {
  local n=$1 avail=$2 cw=$3 cols=1 most rows
  [ "$avail" -lt 1 ] && avail=1
  most=$(((cw - 4) / COLW_MIN))
  [ "$most" -gt 3 ] && most=3
  [ "$most" -lt 1 ] && most=1
  while [ $((cols * avail)) -lt "$n" ] && [ "$cols" -lt "$most" ]; do
    cols=$((cols + 1))
  done
  rows=$(( (n + cols - 1) / cols ))
  [ "$rows" -lt 1 ] && rows=1
  printf '%s %s' "$cols" "$rows"
}

open_popup() {
  local client n ch cw avail chrome cols rows h w
  local -a cflag=()
  if [ -z "${TMUX:-}" ]; then
    printf 'session-select: not inside tmux\n' >&2
    return 1
  fi
  client=${PICKER_CLIENT:-}
  [ -n "$client" ] || client=$(picker_client) || client=""
  [ -n "$client" ] && cflag=(-c "$client")

  n=$(picker_sessions | grep -c '')
  ch=$(tmux display-message ${cflag[@]+"${cflag[@]}"} -p '#{client_height}' 2>/dev/null)
  cw=$(tmux display-message ${cflag[@]+"${cflag[@]}"} -p '#{client_width}' 2>/dev/null)
  case $ch in ''|*[!0-9]*) ch=24 ;; esac
  case $cw in ''|*[!0-9]*) cw=80 ;; esac

  # Rows the list can have in a popup that still fits the client: the popup keeps
  # a row of margin top and bottom, spends two on its border, and four inside on
  # header, blank, blank and footer.
  chrome=1
  avail=$((ch - 8))
  read -r cols rows <<<"$(picker_fit "$n" "$avail" "$cw")"

  # Still too tall even in columns, so the client is very short: give the whole
  # popup over to the list. Dropping the header beats scrolling it away. If it
  # does not fit even then, cap the rows and let render say how many it dropped.
  if [ "$rows" -gt "$avail" ]; then
    chrome=0
    avail=$((ch - 4))
    read -r cols rows <<<"$(picker_fit "$n" "$avail" "$cw")"
    [ "$rows" -gt "$avail" ] && rows=$avail
  fi

  h=$((rows + 2))
  [ "$chrome" = 1 ] && h=$((rows + 6))
  [ "$h" -gt $((ch - 2)) ] && h=$((ch - 2))
  [ "$h" -lt 3 ] && h=3

  if [ "$cols" -gt 1 ]; then w=$((cols * COLW)); else w=$WIDTH; fi
  [ "$w" -gt $((cw - 4)) ] && w=$((cw - 4))

  tmux display-popup ${cflag[@]+"${cflag[@]}"} -E -w "$w" -h "$h" \
    -T " sessions " \
    -e "PICKER_CLIENT=$client" \
    -e "PICKER_COLS=$cols" \
    -e "PICKER_ROWS=$rows" \
    -e "PICKER_CHROME=$chrome" \
    "$(printf '%q --run' "$SELF")"
}

case ${1:-} in
  --run)      run_picker ;;
  ''|--open)  open_popup ;;
  *)
    printf 'usage: %s [--open|--run]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
