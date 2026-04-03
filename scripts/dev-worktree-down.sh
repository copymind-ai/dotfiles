#!/usr/bin/env bash
set -euo pipefail

# Tears down a git worktree and its Docker artifacts.
# Must be run from inside an existing worktree of a bare-cloned repo.
# Usage: git-worktree-down.sh <branch-name>

# --- Usage check ---
if [ -z "${1:-}" ]; then
  echo "Error: branch name is required." >&2
  echo "" >&2
  echo "Usage: dev worktree down <branch-name>" >&2
  echo "Example: dev wt down feat-new-chat" >&2
  exit 1
fi

BRANCH_NAME="$1"

# --- Bare repo check ---
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if ! git -C "$GIT_COMMON_DIR" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
  echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
  exit 1
fi

# --- Resolve paths from current worktree ---
CURRENT_WORKTREE="$(git rev-parse --show-toplevel)"
PARENT_DIR="$(cd "$CURRENT_WORKTREE/.." && pwd)"
REPO_NAME="$(basename "$PARENT_DIR")"

SAFE_NAME="$(echo "$BRANCH_NAME" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-')"
TARGET_DIR="$PARENT_DIR/$SAFE_NAME"
REGISTRY="$PARENT_DIR/.worktree-ports"
PROJECT_NAME="${REPO_NAME}-${SAFE_NAME}"

# --- Validate ---
CURRENT_WORKTREE_NAME="$(basename "$CURRENT_WORKTREE")"
if [ "$SAFE_NAME" = "$CURRENT_WORKTREE_NAME" ]; then
  echo "Error: Cannot tear down the worktree you are currently in." >&2
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory $TARGET_DIR does not exist." >&2
  exit 1
fi

# --- Stop and remove Docker artifacts ---
echo "Stopping Docker containers for $PROJECT_NAME..."
cd "$TARGET_DIR"
docker compose down --rmi local --volumes --remove-orphans 2>/dev/null || true

# --- Supabase note ---
if [ -f "$TARGET_DIR/supabase/config.toml" ]; then
  echo "Note: Shared Supabase instance left running (used by other worktrees)."
  echo "  To stop: dev supabase down"
fi

# --- Remove worktree ---
echo "Removing git worktree..."
cd "$CURRENT_WORKTREE"
git worktree remove "$TARGET_DIR" --force

# --- Optionally delete the branch ---
read -p "Delete local branch '$BRANCH_NAME'? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  git branch -D "$BRANCH_NAME" 2>/dev/null || echo "Branch already deleted or not found"
fi

# --- Remove from port registry ---
if [ -f "$REGISTRY" ]; then
  grep -v "^${SAFE_NAME}	" "$REGISTRY" > "${REGISTRY}.tmp"
  mv "${REGISTRY}.tmp" "$REGISTRY"
  echo "Removed $SAFE_NAME from port registry"
fi

echo ""
echo "=== Teardown complete ==="
echo "  Removed worktree: $TARGET_DIR"
echo "  Freed port for: $SAFE_NAME"
echo "  Docker project '$PROJECT_NAME' cleaned up"
