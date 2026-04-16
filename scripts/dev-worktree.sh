#!/usr/bin/env bash
set -euo pipefail

# Wrapper for git worktree scripts.
# Usage: dev worktree up <branch-name>
#        dev worktree down <branch-name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/dev-worktree-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/dev-worktree-down.sh" "$@"
    ;;
  env)
    shift
    exec "$SCRIPT_DIR/dev-worktree-env.sh" "$@"
    ;;
  info)
    shift
    exec "$SCRIPT_DIR/dev-worktree-info.sh" "$@"
    ;;
  sb|supabase)
    shift
    exec "$SCRIPT_DIR/dev-worktree-supabase.sh" "$@"
    ;;
  *)
    echo "Usage: dev wt <command> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  up <branch>    Create a git worktree with Docker isolation" >&2
    echo "  down <branch>  Tear down a git worktree and free the port" >&2
    echo "  sb             Set up shared Supabase worktree (migration hub)" >&2
    echo "  env            Set up .env.local for current worktree" >&2
    echo "  info           Show info about the current worktree" >&2
    exit 1
    ;;
esac
