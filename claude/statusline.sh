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
# Two things this deliberately does not report: whether Claude is working, and
# whether it is waiting on a prompt. There is no field for the first, and the
# status line is not rendered at all while a permission dialog is up -- verified,
# not assumed -- so the second is impossible here by construction. That is what
# monitor-hook.sh is for.
set -uo pipefail

input=$(cat)

ctx=-1 cost=0 lim5=-1 lim7=-1 rst5=0 rst7=0 sub=-1 model='?' session='' now=0

# One jq for all of it: this runs on every assistant message, so it gets one
# fork and no more. -1 stands in for absent -- used_percentage is null until the
# first API response of a session, and rate_limits only exist on subscriptions.
#
# Joined on a unit separator rather than @tsv. Tab is IFS whitespace, so a run of
# them collapses to one and an empty field in the middle -- a session with no id
# yet -- silently shifts every value after it into the wrong variable.
IFS=$'\037' read -r ctx cost lim5 lim7 rst5 rst7 sub model session now < <(
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
    (now | floor)
  ] | map(tostring) | join("\u001f")' 2>/dev/null
) || true

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

# --- export -----------------------------------------------------------------
# Keyed by tmux server pid and pane id together. Pane numbering restarts with a
# new tmux server, so the pid is what stops a leftover file from a dead server
# being read as this pane's state.
if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
  IFS=, read -r _sock _spid _sid <<<"$TMUX"
  dir=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}
  key="${_spid:-0}-${TMUX_PANE#%}"
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
