#!/usr/bin/env bash
# Creates a tmux session with preconfigured windows for development.
# Usage: dev-session.sh [directory]
# Session name is derived from the directory basename.

DIR="${1:-$(pwd)}"
DIR="$(cd "$DIR" && pwd)" # resolve to absolute path
SESSION="$(basename "$DIR")"

# If already inside tmux, don't nest — just switch
if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$SESSION"
  else
    tmux attach-session -t "$SESSION"
  fi
  exit 0
fi

# Window 1: claude — two horizontal panes
tmux new-session -d -s "$SESSION" -n claude -c "$DIR"
tmux split-window -h -t "$SESSION:claude" -c "$DIR"
tmux select-pane -t "$SESSION:claude.1"

# Window 2: nvim
tmux new-window -t "$SESSION" -n nvim -c "$DIR"

# Window 3: docker
tmux new-window -t "$SESSION" -n docker -c "$DIR"

# Start on the first window
tmux select-window -t "$SESSION:claude"

# Attach
if [ -n "$TMUX" ]; then
  tmux switch-client -t "$SESSION"
else
  tmux attach-session -t "$SESSION"
fi
