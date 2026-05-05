#!/usr/bin/env bash
set -euo pipefail

# Manage env vars across .env.example, .env.local, and Vercel.
# Usage: dev env <add|remove|pull|push> [args]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  add)
    shift
    exec "$SCRIPT_DIR/dev-env-add.sh" "$@"
    ;;
  remove|rm)
    shift
    exec "$SCRIPT_DIR/dev-env-remove.sh" "$@"
    ;;
  pull)
    shift
    exec "$SCRIPT_DIR/dev-env-pull.sh" "$@"
    ;;
  push)
    shift
    exec node "$SCRIPT_DIR/dev-env-push.mjs" "$@"
    ;;
  *)
    echo "Usage: dev env <add|remove|pull|push> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  add [--prod | --dev] <NAME>     Add a var to .env.example, .env.local, and Vercel" >&2
    echo "  remove [--prod | --dev] <NAME>  Remove a var from those places" >&2
    echo "  pull                            Refresh .env.local from Vercel (development env)" >&2
    echo "  push [--force]                  Bulk-push .env.local entries to Vercel development" >&2
    echo "" >&2
    echo "Without flags on add/remove: targets all three Vercel envs (production + preview + development)." >&2
    echo "--prod targets production + preview. --dev targets development only." >&2
    exit 1
    ;;
esac
