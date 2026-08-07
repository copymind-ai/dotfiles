#!/usr/bin/env bash
# Records which Claude Code session was running in which pane, so tmux-resurrect
# can put it back. Wired to @resurrect-hook-post-save-all in .tmux.conf.
#
# Claude already keeps the mapping we need: ~/.claude/sessions/<pid>.json carries
# the session id, the cwd, and the pane the session runs in. What it does not do
# is outlive the process -- those files go when claude goes, so after a reboot
# there is nothing left to read. This copies the three fields that matter into one
# file, keyed by coordinates resurrect will recreate.
#
# Keyed by "<session>:<window index>.<pane index>" rather than by pane id: pane
# ids are per-server and a restored pane gets a new one, while the indexes are
# exactly what resurrect rebuilds from its own save file. The cwd rides along so
# the other side can refuse a match that landed on a pane holding something else.
#
# Written from the post-save hook, not on a timer, so this file and resurrect's
# save describe the same instant. A map fifteen minutes stale is stale in exactly
# the way the layout beside it is, which is the only consistency that matters.
set -uo pipefail

SESSION_DIR=${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}
OUT=${CLAUDE_RESURRECT_MAP:-$HOME/.claude/resurrect-map}

# No jq, no registry, no tmux to ask: nothing to record, and a missing map simply
# means every claude pane comes back as a plain shell.
command -v jq >/dev/null 2>&1 || exit 0
[ -d "$SESSION_DIR" ] || exit 0

# pane id -> coordinates, for the server doing the saving. One tmux call for the
# whole server rather than one per session: this runs inside a save that is
# already forking per pane.
panes=$(tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || exit 0
[ -n "$panes" ] || exit 0

mkdir -p "$(dirname "$OUT")" 2>/dev/null || exit 0
tmp="$OUT.$$"
: > "$tmp" 2>/dev/null || exit 0
trap 'rm -f "$tmp"' EXIT

for f in "$SESSION_DIR"/*.json; do
  [ -f "$f" ] || continue

  # Joined on a unit separator, not @tsv: tab is IFS whitespace, so a session
  # whose cwd or tmux field is empty would collapse two separators into one and
  # shift the session id into the wrong variable.
  sid='' cwd='' tpane=''
  IFS=$'\037' read -r sid cwd tpane < <(
    jq -r '[(.sessionId // ""), (.cwd // ""), (.tmux // "")]
           | map(tostring) | join("\u001f")' "$f" 2>/dev/null
  ) || continue
  [ -n "$sid" ] && [ -n "$cwd" ] && [ -n "$tpane" ] || continue

  # The registry's tmux field is "<session name>:@<window id>.%<pane id>". Only
  # the pane id is matched on -- a session or window can be renamed under a
  # running claude, a pane id cannot change.
  pane_id=${tpane##*.}
  case $pane_id in
    %[0-9]*) ;;
    *) continue ;;
  esac

  # Anything from another tmux server on this machine shares the %N namespace and
  # can collide here. The cwd check on the restore side is what catches that.
  coords=$(printf '%s\n' "$panes" | awk -v p="$pane_id" '$1 == p { print $2; exit }')
  [ -n "$coords" ] || continue

  # A newline in any field would split one record into two and corrupt the read on
  # the other side. None of these can legitimately hold one; drop the record
  # rather than write a broken line.
  case $coords$cwd$sid in
    *$'\n'*|*$'\t'*) continue ;;
  esac

  printf '%s\t%s\t%s\n' "$coords" "$cwd" "$sid" >> "$tmp"
done

# Replaced whole, so a restore reading this file mid-save sees the old map rather
# than half the new one.
if mv -f "$tmp" "$OUT" 2>/dev/null; then
  trap - EXIT
fi
exit 0
