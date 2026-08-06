#!/usr/bin/env bash
# Claude Code status line: one line for you, and a file for the tmux monitor.
#
# Claude pipes the session as JSON on stdin and renders whatever we print, in a
# row of its own between the input box and the mode footer.
#
# The export half is the point. None of these numbers are on the screen for the
# monitor to read, and $TMUX_PANE is in our environment, so we can leave them in
# a file keyed by the very pane the monitor already indexes by. Exporting beats
# parsing the rendered line: the status bar truncates at narrow widths, and
# system notices share the row and can cut it short.
#
# There are two files, and they answer different questions. The per-pane export
# says what is true of the session in that pane right now, and dies with it. The
# spend ledger says what has been spent, day by day, and outlives every session
# in it -- which is the only way the monitor can total a day, a week or a month
# rather than whatever happens to still be running.
#
# Two things this deliberately does not report: whether Claude is working, and
# whether it is waiting on a prompt. There is no field for the first, and the
# status line is not rendered at all while a permission dialog is up -- verified,
# not assumed -- so the second is impossible here by construction. That is what
# monitor-hook.sh is for.
set -uo pipefail

input=$(cat)

ctx=-1 cost=0 lim5=-1 lim7=-1 rst5=0 rst7=0 sub=-1 model='?' session='' now=0 day=''

# One jq for all of it: this runs on every assistant message, so it gets one
# fork and no more. -1 stands in for absent -- used_percentage is null until the
# first API response of a session, and rate_limits only exist on subscriptions.
#
# Joined on a unit separator rather than @tsv. Tab is IFS whitespace, so a run of
# them collapses to one and an empty field in the middle -- a session with no id
# yet -- silently shifts every value after it into the wrong variable.
IFS=$'\037' read -r ctx cost lim5 lim7 rst5 rst7 sub model session now day < <(
  printf '%s' "$input" | jq -r '[
    (.context_window.used_percentage // -1 | floor),
    (.cost.total_cost_usd // 0),
    (.rate_limits.five_hour.used_percentage // -1 | floor),
    (.rate_limits.seven_day.used_percentage // -1 | floor),
    (.rate_limits.five_hour.resets_at // 0),
    (.rate_limits.seven_day.resets_at // 0),
    # How this session is being paid for. rate_limits is only sent to a Claude.ai
    # subscription, so its absence means an API-billed login -- except that it is
    # also absent before the first response of any session, which is what the
    # middle branch is for: no limits but usage already on the clock means API
    # billing; no limits and nothing yet means we cannot tell.
    (if .rate_limits then 1
     elif (.context_window.used_percentage != null)
          or ((.cost.total_cost_usd // 0) > 0) then 0
     else -1 end),
    (.model.display_name // "?"),
    (.session_id // ""),
    (now | floor),
    # The local calendar day, for the spend ledger below. Taken from jq rather
    # than from date, because this runs on every assistant message and jq is
    # already forked -- a second fork would be a third of what the whole script
    # costs, for one string. An old jq without strflocaltime fails the entire
    # filter and every value falls back to the defaults above: the ledger then
    # skips, and nothing else notices.
    # (No apostrophes in here. The filter is single-quoted, so one would end it.)
    (now | strflocaltime("%Y-%m-%d"))
  ] | map(tostring) | join("\u001f")' 2>/dev/null
) || true

# The session id becomes part of two filenames below -- the ledger's and the
# export's -- so a value that is not a plain id is dropped rather than turned into
# a path. Claude has only ever sent a uuid; this is here so that it could not
# matter if that changed. Everything keyed by it then skips, and the rendered line
# is unaffected.
case $session in
  ''|*[!A-Za-z0-9_-]*) session="" ;;
esac

# "1.234" -> CENTS=123, in integer arithmetic because bash has no floats.
CENTS=0
to_cents() {
  local v=$1 whole frac
  case $v in
    *.*) whole=${v%%.*}; frac=${v#*.} ;;
    *)   whole=$v; frac=0 ;;
  esac
  frac=${frac}00; frac=${frac:0:2}
  case $whole in ''|*[!0-9]*) whole=0 ;; esac
  case $frac in ''|*[!0-9]*) frac=0 ;; esac
  CENTS=$((10#$whole * 100 + 10#$frac))
}

# --- spend ledger -------------------------------------------------------------
# What the monitor's per-pane export cannot give it: spend that outlives the
# session that earned it. The .meta file below holds one live session's running
# total and is overwritten by whatever runs in that pane next, so a day's spend
# disappears as its sessions do. This leaves a durable record beside it.
#
# One file per session per day, "<day>.<session id>", holding the cents that
# session has spent on that day. Per session because two sessions writing one
# shared daily file would lose each other's updates; per day because that is the
# grain the monitor totals by, and it means a session running past midnight
# splits across the boundary on its own rather than being counted wherever it
# happened to start.
#
# The file carries its own arithmetic, so no state is needed anywhere else:
# "last" is the session's cumulative cost as of the previous write and "spent"
# the accrual so far, which advances by the difference each time. Truncation to
# cents telescopes -- successive differences of truncated totals add back up to
# the truncated total -- so a run of sub-cent turns is not rounded away.
#
# Not gated on tmux, unlike the export below: this one is keyed by session id,
# so a Claude run outside tmux counts toward the day like any other.
L_SPENT=0; L_LAST=0
l_read() {
  L_SPENT=0; L_LAST=0
  [ -r "$1" ] || return 1
  while IFS='=' read -r _k _v; do
    case $_k in
      spent) L_SPENT=$_v ;;
      last)  L_LAST=$_v ;;
    esac
  done < "$1"
  case $L_SPENT in ''|*[!0-9]*) L_SPENT=0 ;; esac
  case $L_LAST in ''|*[!0-9]*) L_LAST=0 ;; esac
  return 0
}

if [ -n "$session" ] && [ -n "$day" ] && [ "$day" != null ]; then
  ldir=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}/spend
  if mkdir -p "$ldir" 2>/dev/null; then
    l_spent=0 l_last=0
    if l_read "$ldir/$day.$session"; then
      l_spent=$L_SPENT; l_last=$L_LAST
    else
      # First write of a day for this session. "last" has to carry over from the
      # day it wrote before, or the difference is measured against zero and the
      # session drops its entire lifetime cost onto whatever day it happens to
      # cross into -- a session left running past midnight would be counted twice
      # over. The glob is sorted, so the newest earlier day wins, and this runs
      # once per session per day.
      #
      # Nothing to carry from on the very first write of all, so a session that
      # was already running when this was installed puts its history so far into
      # that day. Once, at install, and only for what was already up.
      for _f in "$ldir"/*."$session"; do
        [ -f "$_f" ] || continue
        _d=${_f##*/}; _d=${_d%%.*}
        [[ $_d < $day ]] || continue
        l_read "$_f" && l_last=$L_LAST
      done
    fi

    to_cents "$cost"
    # A cost that went backwards is a session resumed from an earlier point, or
    # one whose id was reused: rebase on the new figure rather than accrue a
    # negative. "last" is rewritten either way, so the next run measures from
    # where this one actually stood.
    [ "$CENTS" -gt "$l_last" ] && l_spent=$((l_spent + CENTS - l_last))

    # Temp file and rename, like the export: the monitor reads these on a timer
    # and a half-written one would total as a half-empty one. "sub" rides along
    # unused by the monitor's own columns, so a later split of the day's spend
    # into subscription and API does not need a new ledger format.
    ltmp="$ldir/.$day.$session.$$"
    if printf 'spent=%s\nlast=%s\nsub=%s\nts=%s\n' \
         "$l_spent" "$CENTS" "$sub" "$now" > "$ltmp" 2>/dev/null
    then
      mv -f "$ltmp" "$ldir/$day.$session" 2>/dev/null || rm -f "$ltmp" 2>/dev/null
    else
      rm -f "$ltmp" 2>/dev/null
    fi
  fi
fi

# --- export -----------------------------------------------------------------
# Keyed by tmux server pid and pane id together, where there is a pane. Pane
# numbering restarts with a new tmux server, so the pid is what stops a leftover
# file from a dead server being read as this pane's state.
#
# Where there is not, the session id does instead. A session with no pane is
# usually a parked job -- `claude` hands long work to a background session under
# its daemon, which does not pass $TMUX_PANE on -- and that session is the one
# actually spending the money the monitor wants to show. It is reached by
# following the pane's parkedJobId; see tmux/monitor.sh and claude/monitor-hook.sh,
# which keys its half the same way.
dir=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}
key=""
if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
  IFS=, read -r _sock _spid _sid <<<"$TMUX"
  key="${_spid:-0}-${TMUX_PANE#%}"
else
  # Checked above, so this is either a plain id or empty -- and empty means no
  # pane and no id to stand in for one, which is nothing we can file.
  [ -n "$session" ] && key="sess-$session"
fi
if [ -n "$key" ]; then
  if mkdir -p "$dir" 2>/dev/null; then

    # --- spend accrued past the subscription -----------------------------
    #
    # There is no field for this. Claude Code knows perfectly well whether it is
    # billing overage -- it keeps isUsingOverage, overageStatus and
    # overageResetsAt from the anthropic-ratelimit-unified-overage-* response
    # headers -- but none of that reaches a status line, a hook, the transcript
    # or any file on disk, and its own UI renders nothing for the ordinary
    # in-overage case. So it is inferred here instead, by watching what the cost
    # does while the windows read full.
    #
    # Each run compares this session's cost against what it exported last time
    # and files the difference under whether a window was exhausted when it was
    # earned. util is clamped to 100 upstream, so "exhausted" is exactly 100 and
    # cannot be read off a higher number.
    #
    # Worth knowing before trusting the figure: once extra usage is enabled the
    # API can report the weekly window as seven_day_overage_included, i.e. with
    # the overage headroom already folded into the denominator, in which case it
    # may never read 100 while overage is being spent and this under-counts.
    # Treat it as a floor, and CLAUDE_OVERAGE_AT as the one knob if the
    # percentage turns out to behave differently.
    over_at=${CLAUDE_OVERAGE_AT:-100}
    over=0
    p_cost=0 p_lim5=-1 p_lim7=-1 p_over=0
    if [ -r "$dir/$key.meta" ]; then
      while IFS='=' read -r _k _v; do
        case $_k in
          cost) p_cost=$_v ;;
          lim5) p_lim5=$_v ;;
          lim7) p_lim7=$_v ;;
          over) p_over=$_v ;;
        esac
      done < "$dir/$key.meta"
    fi
    to_cents "$p_over"; over_c=$CENTS
    to_cents "$p_cost"; prev_c=$CENTS
    to_cents "$cost";   now_c=$CENTS
    # A cost that went backwards means /clear started a new session in this pane,
    # so the difference is meaningless -- rebase on it rather than count it.
    if [ "$now_c" -gt "$prev_c" ]; then
      case $p_lim5$p_lim7 in
        *[!0-9-]*) ;;
        *)
          if [ "$p_lim5" -ge "$over_at" ] 2>/dev/null ||
             [ "$p_lim7" -ge "$over_at" ] 2>/dev/null; then
            over_c=$((over_c + now_c - prev_c))
          fi
          ;;
      esac
    fi
    printf -v over '%d.%02d' $((over_c / 100)) $((over_c % 100))

    tmp="$dir/.$key.meta.$$"
    # Written to a temp file and moved into place: the monitor reads these on a
    # timer and a half-written file would parse as a half-empty one.
    if printf 'ctx=%s\ncost=%s\nover=%s\nlim5=%s\nlim7=%s\nrst5=%s\nrst7=%s\nsub=%s\nmodel=%s\nsession=%s\nts=%s\n' \
         "$ctx" "$cost" "$over" "$lim5" "$lim7" "$rst5" "$rst7" "$sub" \
         "$model" "$session" "$now" > "$tmp" 2>/dev/null
    then
      mv -f "$tmp" "$dir/$key.meta" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

# --- display ----------------------------------------------------------------
# Kept plain: the docs warn that escape sequences in here can collide with other
# UI updates, and this row is also inside the region the monitor scans for a
# dialog footer, so it must not contain anything resembling one.
line="$model"
case $ctx in ''|-1|*[!0-9]*) ;; *) line="$line · ctx ${ctx}%" ;; esac
case $cost in ''|*[!0-9.]*) ;; *) line="$line · $(printf '$%.2f' "$cost")" ;; esac
case $lim5 in ''|-1|*[!0-9]*) ;; *) line="$line · 5h ${lim5}%" ;; esac
case $lim7 in ''|-1|*[!0-9]*) ;; *) line="$line · 7d ${lim7}%" ;; esac

printf '%s\n' "$line"
