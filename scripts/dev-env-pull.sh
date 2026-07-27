#!/usr/bin/env bash
set -euo pipefail

# Refresh .env.local with the current development env from Vercel,
# normalized to flat alphabetical (no comments, no blank lines).
# Usage: dev env pull

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev.helpers.sh"

# --- Resolve worktree root ---
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "Error: must be run inside a git repository" >&2
  exit 1
fi

vercel_check_auth "$ROOT"

# --- Pre-flight: confirm overwrite if .env.local exists ---
if [ -f "$ROOT/.env.local" ]; then
  if ! confirm "Overwrite existing .env.local with Vercel development env?" n; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Pull from Vercel into a temp file ---
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

(cd "$ROOT" && vercel env pull --yes --environment=development "$tmp" >/dev/null 2>&1) || {
  echo "Error: vercel env pull failed" >&2
  exit 1
}

# --- Normalize: keep only KEY=value lines, sort alphabetically (byte order) ---
grep -E '^[A-Z_][A-Z0-9_]*=' "$tmp" | LC_ALL=C sort > "$ROOT/.env.local"

count=$(wc -l < "$ROOT/.env.local" | tr -d ' ')
printf "${GREEN}Pulled %s vars${RESET} from Vercel (development) into %s/.env.local\n" "$count" "$ROOT"

# Backfill + cross-check both depend on .env.example. Skip them cleanly when
# the repo doesn't keep one (the pull itself already succeeded above).
if [ ! -f "$ROOT/.env.example" ]; then
  echo ""
  printf "${DIM}No .env.example — skipping backfill and cross-check.${RESET}\n"
  exit 0
fi

# --- Backfill local-only defaults from .env.example ---
# For keys in .env.example with a non-empty default value (e.g. NODE_ENV=development),
# copy them into .env.local if the key isn't already there. These are local-dev
# tooling vars that don't live on Vercel.
backfilled=0
while IFS='=' read -r key value; do
  [ -z "$key" ] && continue
  [ -z "$value" ] && continue
  if ! grep -q "^${key}=" "$ROOT/.env.local"; then
    upsert_env_sorted "$ROOT/.env.local" "$key" "$value"
    backfilled=$((backfilled + 1))
  fi
done < <(grep -E '^[A-Z_][A-Z0-9_]*=.+' "$ROOT/.env.example")

if [ "$backfilled" -gt 0 ]; then
  printf "${GREEN}Backfilled %s local-only default(s)${RESET} from .env.example\n" "$backfilled"
fi
echo ""

# --- Cross-check against .env.example ---
example_keys="$(grep -oE '^[A-Z_][A-Z0-9_]+=' "$ROOT/.env.example" | sed 's/=$//' | LC_ALL=C sort -u)"
local_keys="$(grep -oE '^[A-Z_][A-Z0-9_]+=' "$ROOT/.env.local" | sed 's/=$//' | LC_ALL=C sort -u)"

missing_locally="$(LC_ALL=C comm -23 <(echo "$example_keys") <(echo "$local_keys"))"
extras_in_local="$(LC_ALL=C comm -13 <(echo "$example_keys") <(echo "$local_keys"))"

if [ -n "$missing_locally" ]; then
  echo "Vars in .env.example but missing from .env.local (set these manually if needed):"
  echo "$missing_locally" | sed 's/^/  - /'
  echo ""
fi

if [ -n "$extras_in_local" ]; then
  echo "Vars on Vercel but missing from .env.example (drift to investigate):"
  echo "$extras_in_local" | sed 's/^/  - /'
  echo ""
fi
