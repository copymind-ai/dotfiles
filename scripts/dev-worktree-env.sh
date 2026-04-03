#!/usr/bin/env bash
set -euo pipefail

# Sets up / refreshes .env.local for the current worktree.
# Injects environment variables from running services (Supabase, etc.).
# Usage: dev worktree env

WORKTREE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$WORKTREE_DIR/.env.local"

# Update or append a key=value pair in a file
upsert_env() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

touch "$ENV_FILE"

# --- Supabase ---
if [ -f "$WORKTREE_DIR/supabase/config.toml" ] && command -v supabase &>/dev/null; then
  if supabase status --output json >/dev/null 2>&1; then
    echo "Injecting Supabase env vars..."
    STATUS_JSON="$(supabase status --output json)"

    upsert_env "$ENV_FILE" "NEXT_PUBLIC_SUPABASE_URL" "$(echo "$STATUS_JSON" | jq -r '.["API URL"]')"
    upsert_env "$ENV_FILE" "NEXT_PUBLIC_SUPABASE_ANON_KEY" "$(echo "$STATUS_JSON" | jq -r '.["anon key"]')"
    upsert_env "$ENV_FILE" "SUPABASE_SERVICE_ROLE_KEY" "$(echo "$STATUS_JSON" | jq -r '.["service_role key"]')"
    upsert_env "$ENV_FILE" "DATABASE_URL" "$(echo "$STATUS_JSON" | jq -r '.["DB URL"]')"

    echo "Updated $ENV_FILE with Supabase connection details."
  else
    echo "Warning: Supabase project detected but not running. Skipping env injection." >&2
    echo "  To start: dev supabase up" >&2
  fi
else
  echo "No Supabase project detected, skipping."
fi

echo "Done: $ENV_FILE"
