#!/usr/bin/env bash
# Re-enters the Claude Code session this pane was running. Sent into the pane by
# tmux-resurrect's process restore -- see @resurrect-processes in .tmux.conf --
# after resurrect has already recreated the pane in the right directory.
#
# exec, never a plain call: the pane's shell has to end up with claude as its
# direct child. resurrect works out what a pane was running by asking ps for the
# shell's child, so a wrapper left sitting in between would be recorded as the
# process next time round, stop matching "claude", and the pane would restore
# exactly once and never again.
#
# Every path out of here ends in an exec of claude, so a pane that cannot be
# resolved still comes back as claude -- just at a fresh conversation rather than
# the one it had.
set -uo pipefail

MAP=${CLAUDE_RESURRECT_MAP:-$HOME/.claude/resurrect-map}
PROJECTS=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}

# This pane's directory under both spellings. The map holds what tmux reported,
# which has symlinks resolved; a shell that was cd'd through a symlink carries the
# link in $PWD, and the same directory under two spellings would read as a miss.
HERE=$PWD
HERE_REAL=$(pwd -P 2>/dev/null) || HERE_REAL=$PWD

# The transcript for a session id, if it is still on disk. Globbed across every
# project directory rather than derived from the cwd: the mapping from a path to
# its project directory is Claude's own slugification, and reimplementing it here
# would be one more thing to keep in step with a version bump.
transcript_exists() { # <session-id>
  local f
  for f in "$PROJECTS"/*/"$1".jsonl; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# The session id recorded for this pane, on stdout. Non-zero if there isn't one to
# be had, which is the common case for a pane whose claude started after the last
# save.
recorded_id() {
  [ -n "${TMUX:-}" ] || return 1
  [ -r "$MAP" ] || return 1

  local coords line cwd sid
  coords=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return 1
  [ -n "$coords" ] || return 1

  line=$(awk -F'\t' -v c="$coords" '$1 == c { print; exit }' "$MAP") || return 1
  [ -n "$line" ] || return 1

  # Split by hand rather than with read: tab is IFS whitespace, so `read` would
  # collapse an empty field and hand back the wrong one.
  cwd=${line#*$'\t'}; cwd=${cwd%$'\t'*}
  sid=${line##*$'\t'}

  # The coordinates alone are not proof. Pane ids are per-server, so a second
  # tmux server on this machine can have written a record under the same
  # coordinates, and the layout may have been edited by hand since the save. If
  # the directory does not agree, this is not that session.
  [ "$cwd" = "$HERE" ] || [ "$cwd" = "$HERE_REAL" ] || return 1

  # A session id reaches exec as an argument, so it is quoted either way -- but a
  # value that is not a plain id means the map has been corrupted, and resuming
  # something arbitrary from a corrupt map is worse than starting fresh.
  case $sid in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac

  transcript_exists "$sid" || return 1
  printf '%s\n' "$sid"
}

# Whether --continue is unambiguous here: nothing in the map claims this
# directory, so the newest conversation in it cannot belong to another pane.
#
# This is the fallback for a pane with no record of its own, which is ordinary --
# a claude started after the last save is invisible to the map, and its
# conversation is almost always the newest one in the directory. There is no
# existence check to go with it: this script only ever runs in a pane that had
# claude running when the save was taken, and such a pane has a transcript in its
# cwd by definition.
#
# When two panes do share a directory -- one project, two conversations, which the
# fleet makes easy to end up with -- both would --continue into the same session
# and show you the same conversation twice, with the second one's edits going
# somewhere you are not looking. A fresh conversation is the safer answer.
sole_claim_on_cwd() {
  [ -r "$MAP" ] || return 0
  local n
  n=$(awk -F'\t' -v d="$HERE" -v r="$HERE_REAL" \
        '$2 == d || $2 == r { c++ } END { print c + 0 }' "$MAP") || return 1
  [ "$n" -eq 0 ]
}

if id=$(recorded_id); then
  exec claude --resume "$id" "$@"
elif sole_claim_on_cwd; then
  exec claude --continue "$@"
fi

exec claude "$@"
