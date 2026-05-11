#!/usr/bin/env bash
set -euo pipefail

# Add an env var to .env.example, .env.local, and Vercel.
# Usage: dev env add [--prod | --dev] <NAME>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev.helpers.sh"

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
# Production and preview vars use --no-sensitive so the value is
# readable later (via vercel env pull / dashboard / dev env pull).
# Development vars don't carry the sensitive flag, so no marker needed.
dev_pushed=0
for env in "${vercel_envs[@]}"; do
  case "$env" in
    production|preview) value="$prod_value" ;;
    development)        value="$dev_value"  ;;
  esac

  if vercel_var_exists "$env" "$name"; then
    if confirm "$name already set in $env. Update?" n; then
      # `--yes` must come before positionals (otherwise Vercel CLI treats it
      # as the optional [gitbranch] arg). Piping `y` is the belt-and-suspenders.
      echo y | vercel env rm --yes "$name" "$env" >/dev/null 2>&1 || true
    else
      printf "${DIM}skip %s (kept existing)${RESET}\n" "$env"
      continue
    fi
  fi

  # Use the Vercel REST API directly — `vercel env add` has interactive
  # prompts that can't be reliably piped (especially the preview-only
  # "Add to which Git branch?" prompt; vercel/vercel#15763). The helper
  # POSTs to /v10/projects/{id}/env with gitBranch=null for preview =
  # "all preview branches".
  err_log="$(mktemp)"
  sensitive_env=""
  # All envs are added as plain (non-sensitive) so dev env pull can
  # round-trip values back into .env.local.
  if VAR_VALUE="$value" SENSITIVE="$sensitive_env" \
       node "$SCRIPT_DIR/dev-env.helpers.mjs" add "$name" "$env" 2>"$err_log"; then
    printf "${GREEN}vercel${RESET}      added %s in %s\n" "$name" "$env"
    [ "$env" = "development" ] && dev_pushed=1
  else
    printf "${RED}vercel${RESET}      failed to add %s in %s:\n" "$name" "$env" >&2
    [ -s "$err_log" ] && sed 's/^/    /' "$err_log" >&2
  fi
  rm -f "$err_log"
done

# --- Mirror development into .env.local ---
# Only write if development was actually pushed to Vercel — otherwise the
# user explicitly skipped the Vercel update and we'd create local/Vercel
# drift by overwriting their existing local value with the new prompt input.
if [ "$write_local" = "1" ] && [ "$dev_pushed" = "1" ]; then
  upsert_env_sorted "$ROOT/.env.local" "$name" "$dev_value"
  printf "${GREEN}.env.local${RESET}  set %s\n" "$name"
fi

printf "\n${GREEN}Done.${RESET} Added %s.\n" "$name"
