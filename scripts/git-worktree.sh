#!/usr/bin/env bash
set -euo pipefail

# Wrapper for git worktree scripts.
# Usage: wt up <branch-name>
#        wt down <branch-name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/git-worktree-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/git-worktree-down.sh" "$@"
    ;;
  *)
    echo "Usage: wt <up|down> <branch-name>" >&2
    exit 1
    ;;
esac
