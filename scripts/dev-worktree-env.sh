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
    sed "s|^${key}=.*|${key}=${val}|" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    # Ensure file ends with a newline before appending to avoid concatenation
    [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo "" >>"$file"
    echo "${key}=${val}" >>"$file"
  fi
}

# Classify a Supabase-related env var name by suffix, echoing the matching
# `supabase status --output json` field (or empty if unmapped).
# Order matters: longer/more-specific suffixes first.
classify_supabase_var() {
  local name="$1"
  case "$name" in
    DATABASE_URL|*_DATABASE_URL)           echo "DB_URL" ;;
    JWT_SECRET)                            echo "JWT_SECRET" ;;
    *SUPABASE*_SERVICE_ROLE_KEY)           echo "SERVICE_ROLE_KEY" ;;
    *SUPABASE*_PUBLISHABLE_KEY)            echo "PUBLISHABLE_KEY" ;;
    *SUPABASE*_SECRET_KEY)                 echo "SECRET_KEY" ;;
    *SUPABASE*_ANON_KEY)                   echo "ANON_KEY" ;;
    *SUPABASE*_URL)                        echo "API_URL" ;;
    *)                                     echo "" ;;
  esac
}

# Discover Supabase-related env var names by scanning source code and the
# existing .env.local. Outputs one unique name per line.
discover_supabase_vars() {
  local worktree="$1" env_file="$2"
  # `|| true` on each branch keeps pipefail from aborting the function
  # when a scanned directory is missing or a grep finds zero matches.
  {
    for dir in "$worktree/src" "$worktree/app" "$worktree/supabase" "$worktree/infra"; do
      if [ -d "$dir" ]; then
        grep -rEoh 'process\.env\.[A-Z_]+' "$dir" 2>/dev/null \
          | sed 's/^process\.env\.//' || true
      fi
    done
    if [ -f "$env_file" ]; then
      grep -oE '^[A-Z_][A-Z0-9_]*=' "$env_file" | tr -d '=' || true
    fi
  } \
    | awk '/SUPABASE/ || $0 == "DATABASE_URL" || $0 == "JWT_SECRET"' \
    | sort -u
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

    # Discover every Supabase-related env var referenced by the app or already
    # declared in .env.local, classify each by name, and populate from the
    # running local Supabase. Every worktree on this machine connects to the
    # same shared local instance, so we always overwrite — remote values are
    # never desired in local dev. URLs get 127.0.0.1 rewritten to localhost so
    # they resolve both from the browser and inside Docker containers (which
    # rely on docker-compose's `extra_hosts: localhost:host-gateway` mapping
    # — see NODE_OPTIONS=--dns-result-order=ipv4first below, which forces
    # Node to pick the host-mapped IPv4 entry instead of ::1).
    while IFS= read -r var_name; do
      [ -z "$var_name" ] && continue
      status_key="$(classify_supabase_var "$var_name")"
      if [ -z "$status_key" ]; then
        echo "  - skipping $var_name (no mapping)"
        continue
      fi

      raw="$(echo "$STATUS_JSON" | jq -r ".${status_key} // empty")"
      if [ -z "$raw" ]; then
        echo "  - skipping $var_name (supabase status missing .${status_key})"
        continue
      fi

      case "$status_key" in
        *_URL) value="$(echo "$raw" | sed 's/127\.0\.0\.1/localhost/')" ;;
        *)     value="$raw" ;;
      esac

      upsert_env "$ENV_FILE" "$var_name" "$value"
      echo "  + $var_name <- .${status_key}"
    done < <(discover_supabase_vars "$WORKTREE_DIR" "$ENV_FILE")

    echo "Updated $ENV_FILE with Supabase connection details."
  else
    echo "Warning: Supabase project detected but not running. Skipping env injection." >&2
    echo "  To start: dev supabase up" >&2
  fi
else
  echo "No Supabase project detected, skipping."
fi

# --- Node IPv4-first for Docker worktrees ---
# When the worktree runs in a container (has a Dockerfile) and the compose
# file uses `extra_hosts: localhost:host-gateway` to map `localhost` to the
# host, we need Node's DNS to prefer IPv4 — otherwise `localhost` resolves
# to IPv6 `::1` (the container itself) and fails to reach host-side Supabase.
# The browser on the host is unaffected; it always uses IPv4 127.0.0.1.
if [ -f "$WORKTREE_DIR/Dockerfile" ]; then
  upsert_env "$ENV_FILE" "NODE_OPTIONS" "--dns-result-order=ipv4first"
  echo "Set NODE_OPTIONS=--dns-result-order=ipv4first (Docker worktree)"
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
