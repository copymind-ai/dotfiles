#!/usr/bin/env bash
set -euo pipefail

# Creates a git worktree with Docker Compose isolation (unique port & project name).
# Must be run from inside an existing worktree of a bare-cloned repo.
# Usage: git-worktree-up.sh <branch-name>

# --- Usage check ---
if [ -z "${1:-}" ]; then
  echo "Error: branch name is required." >&2
  echo "" >&2
  echo "Usage: dev worktree up <branch-name>" >&2
  echo "Example: dev wt up feat-new-chat" >&2
  exit 1
fi

BRANCH_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev-helpers.sh"

require_bare_repo

# --- Must be run from inside an existing worktree ---
if ! CURRENT_WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: No worktree found. Run 'dev wt init' first to bootstrap the repo." >&2
  exit 1
fi
PARENT_DIR="$(cd "$CURRENT_WORKTREE/.." && pwd)"
REPO_NAME="$(basename "$PARENT_DIR" | sed 's/\.git$//')"
CURRENT_WORKTREE_NAME="$(basename "$CURRENT_WORKTREE")"

# Sanitize branch name: replace / with - for Docker and directory naming
SAFE_NAME="$(echo "$BRANCH_NAME" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-')"
NEW_WORKTREE_DIR="$PARENT_DIR/$SAFE_NAME"
REGISTRY="$PARENT_DIR/.worktree-ports"

# --- Validate directory ---
if [ -d "$NEW_WORKTREE_DIR" ]; then
  echo "Error: Directory $NEW_WORKTREE_DIR already exists." >&2
  exit 1
fi

# --- Read base port from docker-compose.yml ---
COMPOSE_FILE="$CURRENT_WORKTREE/docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
  BASE_PORT=$(sed -n 's/.*- *"\([0-9]*\):.*"/\1/p' "$COMPOSE_FILE" | head -1)
fi
if [ -z "${BASE_PORT:-}" ]; then
  echo "Error: Could not read host port from $COMPOSE_FILE" >&2
  exit 1
fi

# --- Registry must exist (created by 'dev wt init') ---
if [ ! -f "$REGISTRY" ]; then
  echo "Error: Port registry not found at $REGISTRY. Run 'dev wt init' first." >&2
  exit 1
fi

# --- Check branch not already registered ---
if grep -q "^${SAFE_NAME}	" "$REGISTRY" 2>/dev/null; then
  echo "Error: '$SAFE_NAME' already has a port in $REGISTRY" >&2
  exit 1
fi

# --- Allocate next port (within 100-port interval) ---
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
if [ "$NEW_PORT" -ge $((BASE_PORT + 100)) ]; then
  echo "Error: Port $NEW_PORT exceeds the 100-port interval ($BASE_PORT–$((BASE_PORT + 99))) for this repo." >&2
  exit 1
fi
echo "Allocated port $NEW_PORT for $SAFE_NAME"

# --- Fetch latest and create worktree ---
echo "Fetching origin..."
git fetch origin

if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
  echo "Local branch $BRANCH_NAME already exists, reusing it..."
  git worktree add "$NEW_WORKTREE_DIR" "$BRANCH_NAME"
elif git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
  echo "Branch $BRANCH_NAME exists on origin, fetching and checking out..."
  git fetch origin "$BRANCH_NAME":"$BRANCH_NAME"
  git worktree add "$NEW_WORKTREE_DIR" "$BRANCH_NAME"
else
  echo "Creating worktree at $NEW_WORKTREE_DIR on new branch $BRANCH_NAME from origin/main..."
  git worktree add -b "$BRANCH_NAME" "$NEW_WORKTREE_DIR" origin/main
fi

# --- Copy .env.local from current worktree ---
if [ -f "$CURRENT_WORKTREE/.env.local" ]; then
  cp "$CURRENT_WORKTREE/.env.local" "$NEW_WORKTREE_DIR/.env.local"
  echo "Copied .env.local from $CURRENT_WORKTREE_NAME"
else
  echo "Warning: No .env.local found in $CURRENT_WORKTREE_NAME worktree" >&2
fi

# --- Generate .env for Docker Compose project name ---
echo "COMPOSE_PROJECT_NAME=${REPO_NAME}-${SAFE_NAME}" >"$NEW_WORKTREE_DIR/.env"
echo "Generated .env with COMPOSE_PROJECT_NAME"

# --- Register port ---
printf "%s\t%s\t%s\n" "$SAFE_NAME" "$NEW_PORT" "$(date +%Y-%m-%d)" >>"$REGISTRY"
echo "Registered in $REGISTRY"

# --- Generate docker-compose.override.yml from the registry ---
(cd "$NEW_WORKTREE_DIR" && "$SCRIPT_DIR/dev-worktree-port.sh")

# --- Install dependencies ---
echo "Installing dependencies..."
cd "$NEW_WORKTREE_DIR"
if [ -f "package-lock.json" ]; then
  npm ci
elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
  bun install
elif [ -f "yarn.lock" ]; then
  yarn install --frozen-lockfile
elif [ -f "pnpm-lock.yaml" ]; then
  pnpm install --frozen-lockfile
fi

# --- Build Docker image ---
echo "Building Docker image..."
docker compose build

# --- Inject Supabase env vars if running ---
HAS_SUPABASE=false
SUPABASE_INJECTED=false
if [ -f "$NEW_WORKTREE_DIR/supabase/config.toml" ] && command -v supabase &>/dev/null; then
  HAS_SUPABASE=true
  if supabase status --output json >/dev/null 2>&1; then
    echo "Injecting Supabase env vars..."
    (cd "$NEW_WORKTREE_DIR" && "$SCRIPT_DIR/dev-worktree-env.sh")
    SUPABASE_INJECTED=true
  fi
fi

echo ""
echo "=== Setup complete ==="
echo "  Worktree:  $NEW_WORKTREE_DIR"
echo "  Branch:    $BRANCH_NAME"
echo "  Port:      $NEW_PORT"
echo "  Container: ${REPO_NAME}-${SAFE_NAME}"
echo ""
echo "To get started:"
echo "  dev s $NEW_WORKTREE_DIR"
if [ "$HAS_SUPABASE" = true ] && [ "$SUPABASE_INJECTED" = false ]; then
  echo "  dev sb up              # start Supabase (if not running)"
  echo "  dev wt env             # pick up Supabase keys into .env.local"
fi
echo "  docker compose up"
