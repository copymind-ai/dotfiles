#!/usr/bin/env bash
set -euo pipefail

# Add an env var to .env.example, .env.local, and Vercel.
# Usage: dev env add [--prod | --dev] <NAME>

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
  echo "Usage: dev env add [--prod | --dev] <NAME>" >&2
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
  all)  vercel_envs=(production preview development); write_local=1 ;;
  prod) vercel_envs=(production preview);             write_local=0 ;;
  dev)  vercel_envs=(development);                    write_local=1 ;;
esac

# --- Update .env.example (idempotent) ---
if grep -q "^${name}=" "$ROOT/.env.example" 2>/dev/null; then
  printf "${DIM}.env.example already has %s — keeping existing entry${RESET}\n" "$name"
else
  upsert_env_sorted "$ROOT/.env.example" "$name" ""
  printf "${GREEN}.env.example${RESET} added %s=\n" "$name"
fi

# --- Prompt for values ---
prod_value=""
dev_value=""
if [ "$mode" = "all" ] || [ "$mode" = "prod" ]; then
  prompt_secret prod_value "Value for $name (production + preview): "
fi
if [ "$mode" = "all" ] || [ "$mode" = "dev" ]; then
  prompt_secret dev_value "Value for $name (development): "
fi

# --- Push to Vercel ---
for env in "${vercel_envs[@]}"; do
  case "$env" in
    production|preview) value="$prod_value" ;;
    development)        value="$dev_value"  ;;
  esac

  if vercel_var_exists "$env" "$name"; then
    if confirm "$name already set in $env. Update?" n; then
      vercel env rm "$name" "$env" -y >/dev/null 2>&1 || true
    else
      printf "${DIM}skip %s (kept existing)${RESET}\n" "$env"
      continue
    fi
  fi

  # Pipe value via stdin; --sensitive=false marks the var as plaintext (readable)
  printf '%s' "$value" \
    | vercel env add "$name" "$env" --sensitive=false >/dev/null 2>&1 \
    || {
      # Older CLIs may not accept --sensitive=false; retry without it (default is non-sensitive)
      printf '%s' "$value" \
        | vercel env add "$name" "$env" >/dev/null 2>&1
    }
  printf "${GREEN}vercel${RESET}      added %s in %s\n" "$name" "$env"
done

# --- Mirror development into .env.local ---
if [ "$write_local" = "1" ]; then
  upsert_env_sorted "$ROOT/.env.local" "$name" "$dev_value"
  printf "${GREEN}.env.local${RESET}  set %s\n" "$name"
fi

printf "\n${GREEN}Done.${RESET} Added %s.\n" "$name"
