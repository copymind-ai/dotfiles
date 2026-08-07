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
# Keys: 1-9 then a-z switch to that session directly, bar the monitor session,
# which is always M -- the key that opens it from outside the picker. hjkl (or
# the arrow keys) move the cursor and enter switches to it; h and l change
# column, so they do nothing while the list is one column wide. x kills the
# session under the cursor, after a y/n confirmation. esc cancels, and any other
# key is ignored rather than closing the popup under you.
#
# Tunables: PICKER_FILTER (regex; only sessions matching it are listed, default
# all), PICKER_WIDTH (popup width, default 56), PICKER_COLW (width of one column
# once the list needs more than one, default 30), MONITOR_SESSION (the session
# that gets the M key, default "monitor" -- the same variable monitor.sh reads).
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
# alphabet less hjkl, which move the cursor instead, less x, which kills, and
# less m, which is held for the monitor. 29 keys in total; anything past that is
# listed without one, and has to be reached with the cursor.
KEYS="123456789abcdefginopqrstuvwyz"

# The monitor session is not keyed by its position in the list: it answers to M
# wherever it sorts, so the key that reaches it from the picker is the one that
# opens it from anywhere else (prefix+M). m is kept out of KEYS above so no other
# session can take it, whether or not the monitor is running, and both cases are
# accepted -- prefix+M is typed with shift, the picker's other keys are not.
MON=${MONITOR_SESSION:-monitor}
MON_KEY="M"

# T_HIDE/T_SHOW hide the terminal's own cursor while the picker is up: it would
# otherwise sit wherever drawing happened to stop -- the bottom right corner --
# reading as a second, wrong cursor next to the row highlight.
#
# T_EL erases to end of line, and ends every line drawn bar the last: a frame is
# painted over the one before it without clearing first, so a line that has grown
# shorter -- the footer coming back after a longer question, say -- would keep the
# tail of what it replaced. The last line needs none; the \033[J that closes a
# frame takes the rest of that line with it.
if [ -t 1 ] || [ -n "${PICKER_FORCE_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  T_HIDE=$'\033[?25l'; T_SHOW=$'\033[?25h'; T_EL=$'\033[K'
else
  C_RST=; C_BOLD=; C_DIM=; C_REV=; C_GRN=; C_YEL=
  T_HIDE=; T_SHOW=; T_EL=
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

# The session the client is on. #{client_session}, not #{session_name}: outside a
# pane the latter reports whichever session was last active, which is not
# necessarily ours.
picker_current() {
  tmux display-message ${PICKER_CLIENT:+-c "$PICKER_CLIENT"} \
    -p '#{client_session}' 2>/dev/null
}

picker_switch() {
  local target=$1 client=${PICKER_CLIENT:-}
  [ -n "$client" ] || client=$(picker_client) || return 1
  tmux switch-client -c "$client" -t "$target" 2>/dev/null
}

# Kills session $1, moving the client onto $2 first when $1 is the one it is
# attached to -- tmux detaches a client whose session is destroyed, which would
# take this popup down with it.
#
# Both go in one tmux run, so they cannot come apart: were the popup to close on
# the switch, a kill issued after it would never be sent. "=" pins the name to an
# exact match; without it tmux falls back to prefix matching, and "work" would
# happily kill "workbench".
picker_kill() {
  local target=$1 fallback=${2:-} client=${PICKER_CLIENT:-}
  [ -n "$client" ] || client=$(picker_client) || client=""
  if [ -n "$fallback" ] && [ -n "$client" ]; then
    tmux switch-client -c "$client" -t "=$fallback" \; \
         kill-session -t "=$target" 2>/dev/null
  else
    tmux kill-session -t "=$target" 2>/dev/null
  fi
}

# --- rendering --------------------------------------------------------------

# Truncation is done inline with ${name:0:nw} rather than by a helper. bash counts
# characters there, not bytes, so a multibyte name is not sliced in half -- and it
# forks nothing. This used to shell out to perl once per row, which cost about
# 5ms each: 100ms of a 125ms frame at twenty sessions, i.e. the whole of the lag
# between a keypress and the redraw. (In a non-UTF-8 locale bash counts bytes and
# a name could still be cut mid-glyph, which is what the old `cut -c` fallback
# did anyway.)

ENTRIES=()    # "windows|attached|name", as listed
SESSIONS=()   # just the names, same order
ROWKEYS=()    # the jump key of each, same order; " " for the ones past the last
ROWS_USED=0   # rows the last render laid out, i.e. what one column step is worth
VISIBLE=0     # entries the last render actually drew; the cursor stays within them
PROMPT=""     # question to put where the footer goes, while one is being asked

# Snapshots the list. The cursor and the drawing have to agree on one list, so
# they both work from this rather than each running tmux themselves.
picker_load() {
  local line name key next=0
  ENTRIES=()
  SESSIONS=()
  ROWKEYS=()
  while IFS= read -r line; do
    name=${line#*|}
    name=${name#*|}
    [ -n "$name" ] || continue
    ENTRIES+=("$line")
    SESSIONS+=("$name")
    # The monitor takes M and spends none of the pool, so the sessions around it
    # keep the keys they would have had were it not running at all.
    if [ "$name" = "$MON" ]; then
      key=$MON_KEY
    else
      key=${KEYS:$next:1}
      [ -n "$key" ] || key=' '   # past the last key: reachable with the cursor only
      next=$((next + 1))
    fi
    ROWKEYS+=("$key")
  done < <(picker_sessions)
}

picker_index_of() { # position of session $1 in SESSIONS, or -1
  local want=$1 i=0
  while [ "$i" -lt ${#SESSIONS[@]} ]; do
    [ "${SESSIONS[$i]}" = "$want" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# Draws the loaded list, with the cursor on entry $6, and records ROWS_USED and
# VISIBLE.
#
# $3 columns, filled top to bottom and then left to right, so the keys read in
# order. More than one column is how a list too tall for the client still shows
# every entry -- letting it scroll would take the header and the first keys off
# the top, which are the ones you reach for most. $4 = 0 drops the header and
# footer too, for a client so short that even the columns do not fit.
render() {
  local cur=$1 w=$2 cols=$3 chrome=${4:-1} maxrows=${5:-0} sel=${6:--1}
  local colw nw wins att name key mark cell i n rows shown r c idx line out=""
  local -a cells=()

  [ "$cols" -ge 1 ] 2>/dev/null || cols=1
  colw=$((w / cols))
  nw=$((colw - 10))
  [ "$nw" -lt 8 ] && nw=8

  n=${#ENTRIES[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    # Split with parameter expansion, not `read <<<`: a here-string per row means
    # a temporary file per row, and this loop runs on every keystroke.
    line=${ENTRIES[$i]}
    wins=${line%%|*}
    att=${line#*|}
    name=${att#*|}
    att=${att%%|*}
    key=${ROWKEYS[$i]}
    # The session this client is on is marked, not hidden, so the keys stay put
    # no matter which session you press prefix+S from.
    if [ "$name" = "$cur" ]; then mark="*"
    elif [ -n "$att" ]; then mark="+"
    else mark=" "; fi
    [ ${#name} -gt "$nw" ] && name=${name:0:nw}
    # printf -v, not $(printf ...): a command substitution per row is another fork
    # per keystroke. Only the name is padded to width -- the colors around it are
    # zero-width, but printf counts bytes, so they must stay outside any %-*s. The
    # two columns the row is indented by hold the cursor mark; it is outside every
    # %-*s too, so a multibyte glyph there cannot skew the padding.
    if [ "$i" = "$sel" ]; then
      # The whole cell in reverse video, and the padding of the name field is
      # what makes it a bar the full width of the column. No inner resets: one
      # would end the highlight halfway across the row. The mark is kept as well,
      # so the cursor is still visible with colors off.
      printf -v cell '%s▸ %s %s%-*s  %2sw%s' \
        "$C_REV" "$key" "$mark" "$nw" "$name" "$wins" "$C_RST"
    else
      printf -v cell '  %s%s%s %s%s%s%-*s%s  %s%2sw%s' \
        "$C_BOLD" "$key" "$C_RST" \
        "$C_YEL" "$mark" "$C_RST" \
        "$nw" "$name" "$C_RST" \
        "$C_DIM" "$wins" "$C_RST"
    fi
    cells+=("$cell")
    i=$((i + 1))
  done

  rows=$(( (n + cols - 1) / cols ))
  [ "$rows" -lt 1 ] && rows=1
  VISIBLE=$n
  # More entries than the popup has room for: spend the last visible cell on
  # saying so, rather than dropping the tail silently.
  if [ "$maxrows" -gt 0 ] && [ "$rows" -gt "$maxrows" ]; then
    rows=$maxrows
    shown=$((cols * rows))
    if [ "$shown" -lt "$n" ] && [ "$shown" -gt 0 ]; then
      cells[$((shown - 1))]=$(printf '  %s... %d more%s' \
        "$C_DIM" "$((n - shown + 1))" "$C_RST")
      VISIBLE=$((shown - 1))   # the notice took the last cell, so it is not an entry
    fi
  fi
  for (( r = 0; r < rows; r++ )); do
    line=""
    for (( c = 0; c < cols; c++ )); do
      idx=$(( c * rows + r ))
      [ "$idx" -lt "$n" ] && line+="${cells[$idx]}"
    done
    out+="$line$T_EL"$'\n'
  done
  ROWS_USED=$rows   # h and l step the cursor by a whole column

  # The last line carries no newline: the popup is sized to fit exactly, and one
  # more would scroll the top off.
  { printf '\033[H'
    if [ "$chrome" = 1 ]; then
      printf '%s%-*s%s\n\n' "${C_REV}${C_BOLD}" "$w" \
        "$(printf ' SESSIONS  %d' "$n")" "$C_RST"
      printf '%s' "$out"
      # A question takes the footer's place rather than a line of its own: the
      # popup is sized to the frame it opened with, and one more line would push
      # the top of the list out of it. The trailing \033[J wipes the second
      # footer line, so the two are never on screen together.
      if [ -n "$PROMPT" ]; then
        printf '%s\n%s%s\n' "$T_EL" "$PROMPT" "$T_EL"
      else
        printf '%s\n%s  %sj/k%s move  %sh/l%s column  %senter%s switch  %sx%s kill%s%s\n' \
          "$T_EL" \
          "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
          "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST" "$T_EL"
        printf '%s  %s1-9/a-z/M%s jump   %sesc%s cancel   %s*%s here   %s+%s attached%s' \
          "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
          "$C_RST$C_YEL" "$C_RST$C_DIM" "$C_RST$C_YEL" "$C_RST$C_DIM" "$C_RST"
      fi
    else
      printf '%s' "${out%$'\n'}"
      # No footer to borrow on a client this short, so the question goes over the
      # last row of the list; the render that follows the answer puts it back.
      [ -n "$PROMPT" ] && printf '\r%s' "$PROMPT"
    fi
    printf '\033[J'
  } 2>/dev/null
}

# Position of the entry keyed $1, or -1. The keys are looked up in the list
# rather than in KEYS because the monitor's is not one of them, and because a
# blank key -- what the entries past the last one carry -- must match nothing.
key_index() {
  local want=$1 i=0
  { [ -n "$want" ] && [ "$want" != ' ' ]; } || { printf -- '-1'; return; }
  # m reaches the monitor as readily as M does: shift is what prefix+M needs,
  # not what the picker's other keys are typed with.
  [ "$want" = m ] && want=$MON_KEY
  while [ "$i" -lt ${#ROWKEYS[@]} ]; do
    [ "${ROWKEYS[$i]}" = "$want" ] && { printf '%s' "$i"; return; }
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

# One keypress, waiting $1 seconds for it (forever when $1 is empty), with the
# arrow keys reported as the hjkl they stand in for. Without that an arrow would
# read as a bare esc and cancel the picker. The fractional timeout is what
# distinguishes "esc alone" from "esc starting a sequence"; bash 3.2 rejects it,
# and there an arrow just cancels.
picker_key() {
  local k rest t=${1:-}
  if [ -n "$t" ]; then
    IFS= read -rsn1 -t "$t" k || return 1
  else
    IFS= read -rsn1 k || return 1
  fi
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

# Puts question $1 where the footer goes and waits for one key, left in ASK_KEY.
# The rest of the arguments are render's own, forwarded as they came.
#
# ASK_KEY is a global because render writes to the terminal: capturing the answer
# with $(...) would run the redraw in a subshell and swallow the question along
# with it.
ASK_KEY=""
picker_ask() {
  local msg=$1
  shift
  PROMPT=$msg
  render "$@"
  ASK_KEY=$(picker_key)
  PROMPT=""
}

# `read -s` only silences the keys it reads itself, so anything typed while the
# list is being drawn is echoed by the terminal -- holding j paints "jjjjj" over
# the popup. Echo goes off for as long as the picker is up instead, and the
# terminal is put back exactly as it was on the way out. SAVED_STTY is global on
# purpose: the trap runs after run_picker's locals are gone.
SAVED_STTY=""

picker_raw_on() {
  trap 'picker_raw_off' EXIT INT TERM
  [ -t 0 ] || return 0
  SAVED_STTY=$(stty -g 2>/dev/null) || SAVED_STTY=""
  stty -echo 2>/dev/null || true
}

picker_raw_off() {
  printf '%s' "$T_SHOW"
  [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
  SAVED_STTY=""
}

run_picker() {
  local cur key idx n lim sel selname leave moved w cols chrome maxrows
  local killreq target neighbour landing name nw msg
  cur=$(picker_current)
  # The layout comes from whoever sized the popup, so it matches the box it was
  # given.
  w=$(term_cols)
  cols=${PICKER_COLS:-1}
  chrome=${PICKER_CHROME:-1}
  maxrows=${PICKER_ROWS:-0}

  picker_load
  n=${#SESSIONS[@]}
  # Start on the session this client is already on: from there j and k reach the
  # neighbours you were most likely after.
  sel=$(picker_index_of "$cur")
  [ "$sel" -ge 0 ] || sel=0

  picker_raw_on
  printf '%s' "$T_HIDE"

  while :; do
    render "$cur" "$w" "$cols" "$chrome" "$maxrows" "$sel"
    [ "$n" -gt 0 ] || break
    [ -t 0 ] || break

    # The cursor stays among the entries actually on screen: on a client too
    # short to show them all, the ones past the end are still jumpable by key,
    # but walking onto them would move a cursor nobody can see.
    lim=$VISIBLE
    { [ "$lim" -gt 0 ] && [ "$lim" -le "$n" ]; } || lim=$n

    key=$(picker_key) || break
    leave=""
    moved=""
    killreq=""
    # Held keys arrive faster than the list can be redrawn, so everything already
    # queued is applied before drawing again -- otherwise the cursor crawls a
    # frame behind the keyboard and keeps moving after the key comes up.
    while :; do
      case $key in
        $'\033') leave=1 ;;
        '')      picker_switch "${SESSIONS[$sel]}"; leave=1 ;;
        j)       sel=$(( (sel + 1) % lim )); moved=1 ;;
        k)       sel=$(( (sel - 1 + lim) % lim )); moved=1 ;;
        l)       moved=1; [ $((sel + ROWS_USED)) -lt "$lim" ] && sel=$((sel + ROWS_USED)) ;;
        h)       moved=1; [ $((sel - ROWS_USED)) -ge 0 ] && sel=$((sel - ROWS_USED)) ;;
        # Asking has to happen with the screen in hand, so it waits until the
        # keys queued behind this one have been applied and the drain is over.
        x)       killreq=1 ;;
        *)
          idx=$(key_index "$key")
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
            picker_switch "${SESSIONS[$idx]}"
            leave=1
          fi
          ;;    # anything else: ignored, so a stray key does not close the popup
      esac
      { [ -n "$leave" ] || [ -n "$killreq" ]; } && break
      key=$(picker_key 0.001) || break
    done
    [ -n "$leave" ] && break

    # x: kill the session under the cursor, once it has been confirmed. The
    # cursor is aimed at the next session beforehand, so it lands on the entry
    # that takes the dead one's place instead of jumping back to the top.
    if [ -n "$killreq" ] && [ "$n" -gt 0 ]; then
      target=${SESSIONS[$sel]}
      neighbour=$target
      if [ "$n" -le 1 ]; then
        # Killing it would end the server, and the picker with it.
        printf -v msg '  %sthe last session cannot be killed%s' "$C_DIM" "$C_RST"
        picker_ask "$msg" "$cur" "$w" "$cols" "$chrome" "$maxrows" "$sel"
      else
        neighbour=${SESSIONS[$(( (sel + 1) % n ))]}
        # The question borrows the footer's row, so it has to fit on it: a line
        # that wrapped would push the top of the list out of the popup. The name
        # gives up whatever room the rest of the line does not need.
        nw=$((w - 15))
        [ "$nw" -lt 4 ] && nw=4
        name=$target
        [ ${#name} -gt "$nw" ] && name=${name:0:nw}
        printf -v msg '  kill %s%s%s?  %sy / n%s' \
          "$C_YEL" "$name" "$C_RST" "$C_DIM" "$C_RST"
        picker_ask "$msg" "$cur" "$w" "$cols" "$chrome" "$maxrows" "$sel"
        if [ "$ASK_KEY" = y ] || [ "$ASK_KEY" = Y ]; then
          if [ "$target" = "$cur" ]; then
            picker_kill "$target" "$neighbour"
          else
            picker_kill "$target"
          fi
          # Where the client ended up is the server's answer, not one worth
          # guessing from whether the kill reported success.
          cur=$(picker_current)
        fi
      fi
      picker_load
      n=${#SESSIONS[@]}
      # The cursor moves on to the neighbour only if the session it was on is
      # really gone; a cancelled -- or failed -- kill leaves it where it was.
      landing=$target
      [ "$(picker_index_of "$target")" -lt 0 ] && landing=$neighbour
      sel=$(picker_index_of "$landing")
      [ "$sel" -ge 0 ] || sel=0
      continue
    fi

    # Moving the cursor cannot have changed the list, so it does not pay for the
    # round trip to the server -- that is another 12ms between key and redraw.
    # Anything else reloads, and puts the cursor back on the session it was on
    # rather than on whatever now holds that index: sessions come and go while
    # this is open.
    if [ -z "$moved" ]; then
      selname=${SESSIONS[$sel]}
      picker_load
      n=${#SESSIONS[@]}
      sel=$(picker_index_of "$selname")
      [ "$sel" -ge 0 ] || sel=0
    fi
  done
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
  # a row of margin top and bottom, spends two on its border, and five inside on
  # header, blank, blank and the two footer lines.
  chrome=1
  avail=$((ch - 9))
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
  [ "$chrome" = 1 ] && h=$((rows + 7))
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
