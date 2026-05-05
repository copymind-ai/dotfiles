#!/usr/bin/env bash
set -euo pipefail

# Remove an env var from .env.example (full remove only), .env.local, and Vercel.
# Usage: dev env remove [--prod | --dev] <NAME>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev-helpers.sh"

# --- Parse args ---
mode="all"
name=""
for arg in "$@"; do
  case "$arg" in
    --prod) [ "$mode" = "all" ] && mode="prod" || { echo "Error: --prod and --dev are mutually exclusive" >&2; exit 1; } ;;
    --dev)  [ "$mode" = "all" ] && mode="dev"  || { echo "Error: --prod and --dev are mutually exclusive" >&2; exit 1; } ;;
    -*) echo "Error: unknown flag: $arg" >&2; exit 1 ;;
    *)  [ -z "$name" ] && name="$arg" || { echo "Error: only one var name allowed" >&2; exit 1; } ;;
  esac
done

if [ -z "$name" ]; then
  echo "Error: variable name is required" >&2
  echo "Usage: dev env remove [--prod | --dev] <NAME>" >&2
  exit 1
fi

if ! [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  echo "Error: name must match ^[A-Z_][A-Z0-9_]*$ (e.g. MY_VAR)" >&2
  exit 1
fi

# --- Resolve worktree root ---
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/.env.example" ]; then
  echo "Error: must be run inside a worktree containing .env.example" >&2
  exit 1
fi

vercel_check_auth "$ROOT"

# --- Determine targets ---
case "$mode" in
  all)  vercel_envs=(production preview development); remove_local=1; remove_example=1 ;;
  prod) vercel_envs=(production preview);             remove_local=0; remove_example=0 ;;
  dev)  vercel_envs=(development);                    remove_local=1; remove_example=0 ;;
esac

# --- Show plan & confirm ---
echo "Will remove $name from:"
for env in "${vercel_envs[@]}"; do echo "  - Vercel ($env)"; done
[ "$remove_local"   = "1" ] && echo "  - $ROOT/.env.local"
[ "$remove_example" = "1" ] && echo "  - $ROOT/.env.example"
echo ""

if ! confirm "Proceed?" n; then
  echo "Aborted."
  exit 0
fi

# --- Remove from Vercel ---
# `--yes` must come before positionals — otherwise Vercel CLI parses it as
# the optional [gitbranch] arg and the interactive prompt silently aborts
# with stdin closed. Piping `y` is a belt-and-suspenders safety net.
for env in "${vercel_envs[@]}"; do
  if vercel_var_exists "$env" "$name"; then
    err_log="$(mktemp)"
    if echo y | vercel env rm --yes "$name" "$env" >/dev/null 2>"$err_log"; then
      printf "${GREEN}vercel${RESET}      removed %s from %s\n" "$name" "$env"
    else
      printf "${RED}vercel${RESET}      failed to remove %s from %s:\n" "$name" "$env" >&2
      sed 's/^/    /' "$err_log" >&2
    fi
    rm -f "$err_log"
  else
    printf "${DIM}vercel${RESET}      skip %s (not set in %s)\n" "$name" "$env"
  fi
done

# --- Remove from .env.local ---
if [ "$remove_local" = "1" ]; then
  remove_env "$ROOT/.env.local" "$name"
  printf "${GREEN}.env.local${RESET}  removed %s\n" "$name"
fi

# --- Remove from .env.example ---
if [ "$remove_example" = "1" ]; then
  remove_env "$ROOT/.env.example" "$name"
  printf "${GREEN}.env.example${RESET} removed %s\n" "$name"
fi

printf "\n${GREEN}Done.${RESET} Removed %s.\n" "$name"
