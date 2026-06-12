#!/usr/bin/env bash
set -euo pipefail

# dev CLI — unified entry point for development tools.
# Usage: dev <command> [args]
#
# Commands:
#   s,   session    Tmux dev sessions
#   sb,  supabase   Shared local Supabase instance
#   wt,  worktree   Git worktrees with Docker isolation
#   e,   env        Manage env vars across .env.example, .env.local, Vercel
#   nc,  nanoclaw   Manage the NanoClaw host service via launchd
#   upd, update     Pull latest dotfiles changes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Toolchain PATH for non-interactive (agent) shells ---
# Agents (e.g. the devops bot) invoke `dev` from a non-interactive shell that
# never sources the operator's login profile, so Homebrew/nvm bins are absent
# and subcommands die on "npm/supabase/docker: command not found". Prepend the
# standard locations (idempotent, only if present) and load nvm's default node.
# Exported so the exec'd subcommand inherits it. Must never error under set -e.
for __dir in /opt/homebrew/bin /usr/local/bin /Applications/Docker.app/Contents/Resources/bin; do
  case ":$PATH:" in
    *":$__dir:"*) : ;;
    *) if [ -d "$__dir" ]; then PATH="$__dir:$PATH"; fi ;;
  esac
done
export PATH
unset __dir
if ! command -v npm >/dev/null 2>&1 && [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  nvm use default >/dev/null 2>&1 || true
fi

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
  e|env)
    shift
    exec "$SCRIPT_DIR/dev-env.sh" "$@"
    ;;
  nc|nanoclaw)
    shift
    exec "$SCRIPT_DIR/dev-nanoclaw.sh" "$@"
    ;;
  upd|update)
    shift
    exec "$SCRIPT_DIR/dev-update.sh" "$@"
    ;;
  *)
    echo "Usage: dev <command> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  s,   session    Tmux dev sessions" >&2
    echo "  sb,  supabase   Shared local Supabase instance" >&2
    echo "  wt,  worktree   Git worktrees with Docker isolation" >&2
    echo "  e,   env        Manage env vars across .env.example, .env.local, Vercel" >&2
    echo "  nc,  nanoclaw   Manage the NanoClaw host service via launchd" >&2
    echo "  upd, update     Pull latest dotfiles changes" >&2
    echo "" >&2
    echo "Run 'dev <command>' to see subcommands." >&2
    exit 1
    ;;
esac
