#!/usr/bin/env bash
set -euo pipefail

# dev CLI — unified entry point for development tools.
# Usage: dev <command> [args]
#
# Commands:
#   s,  session    Tmux dev sessions
#   sb, supabase   Shared local Supabase instance
#   wt, worktree   Git worktrees with Docker isolation
#   update         Pull latest dotfiles changes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  s|session)
    shift
    exec "$SCRIPT_DIR/dev-session.sh" "$@"
    ;;
  wt|worktree)
    shift
    exec "$SCRIPT_DIR/dev-worktree.sh" "$@"
    ;;
  sb|supabase)
    shift
    exec "$SCRIPT_DIR/dev-supabase.sh" "$@"
    ;;
  update)
    shift
    exec "$SCRIPT_DIR/dev-update.sh" "$@"
    ;;
  *)
    echo "Usage: dev <command> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  s,  session    Tmux dev sessions" >&2
    echo "  sb, supabase   Shared local Supabase instance" >&2
    echo "  wt, worktree   Git worktrees with Docker isolation" >&2
    echo "  update         Pull latest dotfiles changes" >&2
    echo "" >&2
    echo "Run 'dev <command>' to see subcommands." >&2
    exit 1
    ;;
esac
