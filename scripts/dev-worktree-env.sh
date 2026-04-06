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

    # Docker-specific: server-side code inside containers can't reach "localhost"
    # on the host. SUPABASE_DOCKER_URL uses host.docker.internal instead.
    # NEXT_PUBLIC_SUPABASE_COOKIE_NAME aligns cookie names between browser (localhost)
    # and server (host.docker.internal) Supabase URLs.
    DOCKER_API_URL="$(echo "$API_URL" | sed 's/localhost/host.docker.internal/')"
    upsert_env "$ENV_FILE" "SUPABASE_DOCKER_URL" "$DOCKER_API_URL"
    upsert_env "$ENV_FILE" "NEXT_PUBLIC_SUPABASE_COOKIE_NAME" "sb-localhost-auth-token"

    echo "Updated $ENV_FILE with Supabase connection details."
  else
    echo "Warning: Supabase project detected but not running. Skipping env injection." >&2
    echo "  To start: dev supabase up" >&2
  fi
else
  echo "No Supabase project detected, skipping."
fi

echo "Done: $ENV_FILE"
