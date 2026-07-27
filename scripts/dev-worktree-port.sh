#!/usr/bin/env bash
set -euo pipefail

# Generates docker-compose.override.yml for the current worktree from its
# entry in the port registry (.worktree-ports). The registry is the single
# source of truth; this script just projects that truth into a per-worktree
# override file. Shared by `dev wt init` and `dev wt up`.
# Usage: dev wt port

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/templates/docker-compose.override.yml"
WORKTREE_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Error: Not inside a git worktree." >&2
  exit 1
}
WORKTREE_NAME="$(basename "$WORKTREE_DIR")"
PARENT_DIR="$(cd "$WORKTREE_DIR/.." && pwd)"
REPO_NAME="$(basename "$PARENT_DIR" | sed 's/\.git$//')"
REGISTRY="$PARENT_DIR/.worktree-ports"
OVERRIDE_FILE="$WORKTREE_DIR/docker-compose.override.yml"

# --- Registry check ---
if [ ! -f "$REGISTRY" ]; then
  echo "Error: Port registry not found at $REGISTRY. Run 'dev wt init' first." >&2
  exit 1
fi

# --- Look up this worktree's port ---
PORT="$(awk -F'\t' -v n="$WORKTREE_NAME" '$1 == n {print $2; exit}' "$REGISTRY")"
if [ -z "$PORT" ]; then
  echo "Error: No entry for '$WORKTREE_NAME' in $REGISTRY" >&2
  exit 1
fi

# --- Template check ---
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: Template not found at $TEMPLATE" >&2
  exit 1
fi

# --- Detect the service name from docker-compose.yml ---
# The override must target the SAME service defined in the base compose file;
# hardcoding a name (e.g. "app") makes Compose treat the override as a new,
# build-less service → "neither an image nor a build context" errors. Grab the
# first service key under `services:` (the app service, by convention first).
COMPOSE_FILE="$WORKTREE_DIR/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: docker-compose.yml not found at $COMPOSE_FILE" >&2
  exit 1
fi
SERVICE_NAME="$(awk '
  /^services:[[:space:]]*$/ { in_s=1; next }
  in_s && /^[^[:space:]#]/  { exit }               # dedented to top level → stop
  in_s && /^[[:space:]]+[A-Za-z0-9._-]+:/ {
    gsub(/[[:space:]:]/, ""); print; exit
  }
' "$COMPOSE_FILE")"
if [ -z "$SERVICE_NAME" ]; then
  echo "Error: Could not detect a service name in $COMPOSE_FILE" >&2
  exit 1
fi

# --- Render template ---
CONTAINER_NAME="${REPO_NAME}-${WORKTREE_NAME}"
sed \
  -e "s|__SERVICE_NAME__|${SERVICE_NAME}|g" \
  -e "s|__CONTAINER_NAME__|${CONTAINER_NAME}|g" \
  -e "s|__PORT__|${PORT}|g" \
  "$TEMPLATE" > "$OVERRIDE_FILE"
echo "Generated docker-compose.override.yml (host port $PORT -> container 3000)"
