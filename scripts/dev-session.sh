#!/usr/bin/env bash
# Creates a tmux session with preconfigured windows for development.
# Usage: dev-session.sh [-n name] [directory]
# Session name defaults to the directory basename.

SESSION_NAME=""
while getopts "n:" opt; do
  case $opt in
    n) SESSION_NAME="$OPTARG" ;;
    *) echo "Usage: dev-session.sh [-n name] [directory]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

DIR="${1:-$(pwd)}"
DIR="$(cd "$DIR" && pwd)" # resolve to absolute path
SESSION="${SESSION_NAME:-$(basename "$DIR")}"

# If already inside tmux, don't nest — just switch
if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$SESSION"
  else
    tmux attach-session -t "$SESSION"
  fi
  exit 0
fi

# Window 1: claude
tmux new-session -d -s "$SESSION" -n claude -c "$DIR"

# Window 2: nvim
tmux new-window -t "$SESSION" -n nvim -c "$DIR"

# Start on the first window
tmux select-window -t "$SESSION:claude"

# Attach
if [ -n "$TMUX" ]; then
  tmux switch-client -t "$SESSION"
else
  tmux attach-session -t "$SESSION"
fi
