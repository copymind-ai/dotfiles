#!/usr/bin/env bash
set -euo pipefail

# Sets up the shared Supabase worktree (migration hub) and starts the Supabase stack.
# The supabase worktree is checked out at origin/main and serves as the single
# source of truth for all migrations. Feature worktrees symlink their new
# migrations into it via `dev sb migrate`.
#
# Usage: dev wt sb
# Idempotent: safe to re-run — updates to latest origin/main and applies new migrations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Require supabase CLI ---
if ! command -v supabase &>/dev/null; then
  echo "Error: supabase CLI not found. Install via: brew install supabase/tap/supabase" >&2
  exit 1
fi

# --- Bare repo check ---
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if ! git -C "$GIT_COMMON_DIR" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
  echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
  exit 1
fi

# --- Resolve paths ---
CURRENT_WORKTREE="$(git rev-parse --show-toplevel)"
PARENT_DIR="$(cd "$CURRENT_WORKTREE/.." && pwd)"
SUPABASE_WT="$PARENT_DIR/supabase"

# --- Ensure fetch refspec exists (bare clones don't configure one) ---
if ! git config --get remote.origin.fetch &>/dev/null; then
  git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
fi

echo "Fetching origin..."
git fetch origin

# --- Create or update supabase worktree ---
if [ -d "$SUPABASE_WT" ]; then
  echo "Updating supabase worktree to origin/main..."
  (cd "$SUPABASE_WT" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
else
  echo "Creating supabase worktree..."
  git worktree add "$SUPABASE_WT" --detach origin/main
fi

# --- Start Supabase if not running ---
if supabase status --output json >/dev/null 2>&1; then
  echo "Supabase already running."
else
  echo "Starting Supabase..."
  echo "(First run pulls ~10 Docker images and may take a few minutes)"
  (cd "$SUPABASE_WT" && supabase start)
fi

# --- Apply origin/main migrations ---
echo "Applying origin/main migrations..."
if [ -x "$SUPABASE_WT/scripts/db-migrate-local.sh" ]; then
  (cd "$SUPABASE_WT" && ./scripts/db-migrate-local.sh)
else
  (cd "$SUPABASE_WT" && supabase migration up --local)
fi

# --- Inject env vars ---
echo "Injecting Supabase env vars..."
(cd "$SUPABASE_WT" && "$SCRIPT_DIR/dev-worktree-env.sh")

# --- Summary ---
echo ""
echo "=== Supabase hub ready ==="
echo "  Worktree: $SUPABASE_WT"
echo "  Branch:   origin/main (detached)"
echo ""
echo "To apply feature migrations: dev sb migrate"
