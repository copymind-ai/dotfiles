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

# --- Bare repo check ---
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if ! git -C "$GIT_COMMON_DIR" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
  echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
  exit 1
fi

# --- Resolve paths from current worktree ---
CURRENT_WORKTREE="$(git rev-parse --show-toplevel)"
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

# --- Initialize registry if missing ---
if [ ! -f "$REGISTRY" ]; then
  printf "# worktree\tport\tcreated\n" >"$REGISTRY"
  printf "%s\t%s\t%s\n" "$CURRENT_WORKTREE_NAME" "$BASE_PORT" "$(date +%Y-%m-%d)" >>"$REGISTRY"
  echo "Initialized port registry at $REGISTRY (base port $BASE_PORT)"
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
# Bare clones don't configure a fetch refspec, so origin/* refs never get created.
# Fix that before fetching so origin/main resolves properly.
if ! git config --get remote.origin.fetch &>/dev/null; then
  git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
fi
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

# --- Supabase integration ---
if [ -f "$NEW_WORKTREE_DIR/supabase/config.toml" ]; then
  if ! command -v supabase &>/dev/null; then
    echo "Warning: supabase CLI not found. Skipping Supabase setup." >&2
  else
    if ! supabase status --output json >/dev/null 2>&1; then
      echo "Error: Supabase is not running. Set it up first: dev wt sb" >&2
      exit 1
    fi

    # Inject Supabase env vars into .env.local
    (cd "$NEW_WORKTREE_DIR" && "$SCRIPT_DIR/dev-worktree-env.sh")

    # Refresh supabase wt to latest origin/main and apply new base migrations
    echo "Refreshing migration hub..."
    SUPABASE_WT=$("$SCRIPT_DIR/dev-worktree-migrate.sh" find-supabase-wt)
    (cd "$SUPABASE_WT" && git fetch origin && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
    if [ -x "$SUPABASE_WT/scripts/db-migrate-local.sh" ]; then
      (cd "$SUPABASE_WT" && ./scripts/db-migrate-local.sh)
    else
      (cd "$SUPABASE_WT" && supabase migration up --local)
    fi
    echo "Migration hub refreshed to origin/main"
  fi
fi

# --- Generate .env for Docker Compose project name ---
echo "COMPOSE_PROJECT_NAME=${REPO_NAME}-${SAFE_NAME}" >"$NEW_WORKTREE_DIR/.env"
echo "Generated .env with COMPOSE_PROJECT_NAME"

# --- Generate docker-compose.override.yml ---
cat >"$NEW_WORKTREE_DIR/docker-compose.override.yml" <<EOF
services:
  app:
    container_name: ${REPO_NAME}-${SAFE_NAME}
    ports: !override
      - "${NEW_PORT}:3000"
EOF
echo "Generated docker-compose.override.yml (host port $NEW_PORT -> container 3000)"

# --- Register port ---
printf "%s\t%s\t%s\n" "$SAFE_NAME" "$NEW_PORT" "$(date +%Y-%m-%d)" >>"$REGISTRY"
echo "Registered in $REGISTRY"

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

echo ""
echo "=== Setup complete ==="
echo "  Worktree:  $NEW_WORKTREE_DIR"
echo "  Branch:    $BRANCH_NAME"
echo "  Port:      $NEW_PORT"
echo "  Container: ${REPO_NAME}-${SAFE_NAME}"
echo ""
echo "To get started:"
echo "  cd $NEW_WORKTREE_DIR"
echo "  docker compose up"
