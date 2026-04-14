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
    # Ensure file ends with a newline before appending to avoid concatenation
    [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo "" >>"$file"
    echo "${key}=${val}" >>"$file"
  fi
}

touch "$ENV_FILE"

# --- Supabase ---
# SUPABASE_STATUS_DIR overrides where `supabase status` runs.
# Needed when the current worktree's config.toml has different ports
# than the shared running Supabase instance.
STATUS_DIR="${SUPABASE_STATUS_DIR:-$WORKTREE_DIR}"
if [ -f "$WORKTREE_DIR/supabase/config.toml" ] && command -v supabase &>/dev/null; then
  if (cd "$STATUS_DIR" && supabase status --output json) >/dev/null 2>&1; then
    echo "Injecting Supabase env vars..."
    STATUS_JSON="$(cd "$STATUS_DIR" && supabase status --output json 2>/dev/null | sed -n '/^{/,/^}/p')"

    # Replace 127.0.0.1 with localhost so URLs resolve both from the browser
    # and from inside Docker containers (via extra_hosts: localhost:host-gateway)
    API_URL="$(echo "$STATUS_JSON" | jq -r '.API_URL' | sed 's/127\.0\.0\.1/localhost/')"
    DB_URL="$(echo "$STATUS_JSON" | jq -r '.DB_URL' | sed 's/127\.0\.0\.1/localhost/')"

    upsert_env "$ENV_FILE" "NEXT_PUBLIC_SUPABASE_URL" "$API_URL"
    upsert_env "$ENV_FILE" "NEXT_PUBLIC_SUPABASE_ANON_KEY" "$(echo "$STATUS_JSON" | jq -r '.ANON_KEY')"
    upsert_env "$ENV_FILE" "SUPABASE_SERVICE_ROLE_KEY" "$(echo "$STATUS_JSON" | jq -r '.SERVICE_ROLE_KEY')"
    upsert_env "$ENV_FILE" "DATABASE_URL" "$DB_URL"

    echo "Updated $ENV_FILE with Supabase connection details."
  else
    echo "Warning: Supabase project detected but not running. Skipping env injection." >&2
    echo "  To start: dev supabase up" >&2
  fi
else
  echo "No Supabase project detected, skipping."
fi

# --- COPYMIND_API_HOST for Supabase Edge Functions ---
# Edge functions run inside Docker (Supabase edge runtime) and need
# host.docker.internal to reach the app container on the host.
# Read the allocated port from docker-compose.override.yml or default to 3000.
APP_PORT=3000
OVERRIDE_FILE="$WORKTREE_DIR/docker-compose.override.yml"
if [ -f "$OVERRIDE_FILE" ]; then
  OVERRIDE_PORT="$(grep -oE '[0-9]+:3000' "$OVERRIDE_FILE" | head -1 | cut -d: -f1)"
  if [ -n "$OVERRIDE_PORT" ]; then
    APP_PORT="$OVERRIDE_PORT"
  fi
fi
upsert_env "$ENV_FILE" "COPYMIND_API_HOST" "http://host.docker.internal:${APP_PORT}"
echo "Set COPYMIND_API_HOST=http://host.docker.internal:${APP_PORT}"

echo "Done: $ENV_FILE"
