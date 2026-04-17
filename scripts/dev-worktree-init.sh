#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the first worktree from a bare-cloned repo.
# Run this once after `git clone --bare` to set up the initial working directory.
# Usage: dev wt init

# --- Bare repo check ---
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" || {
  echo "Error: Not inside a git repository." >&2
  exit 1
}
if ! git -C "$GIT_COMMON_DIR" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
  echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
  exit 1
fi

# --- Check no worktrees exist yet ---
WT_COUNT=$(git worktree list | wc -l | tr -d ' ')
if [ "$WT_COUNT" -gt 1 ]; then
  echo "Error: Worktrees already exist. Use 'dev wt up <branch>' instead." >&2
  exit 1
fi

# --- Resolve paths ---
BARE_DIR="$(cd "$GIT_COMMON_DIR" && pwd)"
PARENT_DIR="$(cd "$BARE_DIR/.." && pwd)"
REPO_NAME="$(basename "$BARE_DIR" | sed 's/\.git$//')"
WORKTREE_DIR="$PARENT_DIR/main"

if [ -d "$WORKTREE_DIR" ]; then
  echo "Error: Directory $WORKTREE_DIR already exists." >&2
  exit 1
fi

# --- Configure fetch refspec if missing ---
if ! git config --get remote.origin.fetch &>/dev/null; then
  git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
fi

# --- Fetch and detect default branch ---
echo "Fetching origin..."
git fetch origin

DEFAULT_BRANCH=""
if git show-ref --verify --quiet refs/heads/main 2>/dev/null || git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  DEFAULT_BRANCH="main"
elif git show-ref --verify --quiet refs/heads/master 2>/dev/null || git ls-remote --exit-code --heads origin master >/dev/null 2>&1; then
  DEFAULT_BRANCH="master"
else
  DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
fi

if [ -z "$DEFAULT_BRANCH" ]; then
  echo "Error: Could not detect default branch from origin." >&2
  exit 1
fi

# --- Create first worktree ---
echo "Creating worktree at $WORKTREE_DIR on branch $DEFAULT_BRANCH..."
if git show-ref --verify --quiet "refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
  git worktree add "$WORKTREE_DIR" "$DEFAULT_BRANCH"
else
  git fetch origin "$DEFAULT_BRANCH":"$DEFAULT_BRANCH"
  git worktree add "$WORKTREE_DIR" "$DEFAULT_BRANCH"
fi

# --- Initialize port registry ---
COMPOSE_FILE="$WORKTREE_DIR/docker-compose.yml"
REGISTRY="$PARENT_DIR/.worktree-ports"
if [ -f "$COMPOSE_FILE" ]; then
  BASE_PORT=$(sed -n 's/.*- *"\([0-9]*\):.*"/\1/p' "$COMPOSE_FILE" | head -1)
fi
if [ -n "${BASE_PORT:-}" ]; then
  printf "# worktree\tport\tcreated\n" >"$REGISTRY"
  printf "%s\t%s\t%s\n" "main" "$BASE_PORT" "$(date +%Y-%m-%d)" >>"$REGISTRY"
  echo "Initialized port registry at $REGISTRY (base port $BASE_PORT)"
else
  echo "Warning: No host port found in docker-compose.yml — port registry not created." >&2
fi

echo ""
echo "=== Init complete ==="
echo "  Worktree:  $WORKTREE_DIR"
echo "  Branch:    $DEFAULT_BRANCH"
[ -n "${BASE_PORT:-}" ] && echo "  Base port: $BASE_PORT"
echo ""
echo "To get started:"
echo "  cd $WORKTREE_DIR"
echo "  dev wt up <branch-name>   # create additional worktrees"
