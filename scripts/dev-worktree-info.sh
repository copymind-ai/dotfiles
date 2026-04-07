#!/usr/bin/env bash
set -euo pipefail

# Shows information about the current worktree set up with `dev wt up`.
# Must be run from inside a worktree of a bare-cloned repo.
# Usage: dev wt info

# --- Bare repo check ---
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if ! git -C "$GIT_COMMON_DIR" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
  echo "Error: Not inside a bare-repo worktree." >&2
  exit 1
fi

# --- Resolve paths ---
WORKTREE_DIR="$(git rev-parse --show-toplevel)"
WORKTREE_NAME="$(basename "$WORKTREE_DIR")"
PARENT_DIR="$(cd "$WORKTREE_DIR/.." && pwd)"
REPO_NAME="$(basename "$PARENT_DIR")"
REGISTRY="$PARENT_DIR/.worktree-ports"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
PROJECT_NAME="${REPO_NAME}-${WORKTREE_NAME}"

# --- Port from registry ---
PORT="—"
CREATED="—"
if [ -f "$REGISTRY" ]; then
  ENTRY=$(grep "^${WORKTREE_NAME}	" "$REGISTRY" 2>/dev/null || true)
  if [ -n "$ENTRY" ]; then
    PORT=$(echo "$ENTRY" | awk -F'\t' '{print $2}')
    CREATED=$(echo "$ENTRY" | awk -F'\t' '{print $3}')
  fi
fi

# --- Docker container status ---
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "$PROJECT_NAME" 2>/dev/null || true)
if [ -z "$CONTAINER_STATUS" ]; then
  CONTAINER_STATUS="not found"
fi

# --- Docker image ---
IMAGE_INFO="not built"
IMAGE_ID=$(docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' \
  --filter "reference=${PROJECT_NAME}*" 2>/dev/null | head -1 || true)
if [ -n "$IMAGE_ID" ]; then
  IMAGE_INFO="$IMAGE_ID"
fi

# --- Supabase status ---
SUPABASE_STATUS=""
if [ -f "$WORKTREE_DIR/supabase/config.toml" ] && command -v supabase &>/dev/null; then
  if supabase status --output json 2>/dev/null | sed -n '/^{/,/^}/p' | jq -e '.API_URL' &>/dev/null; then
    SUPABASE_STATUS="running"
    SUPABASE_API_URL=$(cd "$WORKTREE_DIR" && supabase status --output json 2>/dev/null \
      | sed -n '/^{/,/^}/p' | jq -r '.API_URL // empty')
    SUPABASE_STUDIO_URL=$(cd "$WORKTREE_DIR" && supabase status --output json 2>/dev/null \
      | sed -n '/^{/,/^}/p' | jq -r '.STUDIO_URL // empty')
  else
    SUPABASE_STATUS="stopped"
  fi
fi

# --- Print info ---
echo ""
echo "=== Worktree Info ==="
echo "  Worktree:   $WORKTREE_DIR"
echo "  Branch:     $BRANCH"
echo "  Created:    $CREATED"
echo ""
echo "=== Docker ==="
echo "  Project:    $PROJECT_NAME"
echo "  Container:  $CONTAINER_STATUS"
echo "  Image:      $IMAGE_INFO"
echo "  Port:       ${PORT} -> 3000"
if [ "$PORT" != "—" ]; then
  echo "  URL:        http://localhost:${PORT}"
fi
echo ""

if [ -n "$SUPABASE_STATUS" ]; then
  echo "=== Supabase ==="
  echo "  Status:     $SUPABASE_STATUS"
  if [ "$SUPABASE_STATUS" = "running" ]; then
    [ -n "${SUPABASE_API_URL:-}" ] && echo "  API:        $SUPABASE_API_URL"
    [ -n "${SUPABASE_STUDIO_URL:-}" ] && echo "  Studio:     $SUPABASE_STUDIO_URL"
  fi
  echo ""
fi

# --- Other worktrees summary ---
echo "=== All Worktrees ==="
if [ -f "$REGISTRY" ]; then
  printf "  %-25s %-8s %s\n" "NAME" "PORT" "CREATED"
  grep -v '^#' "$REGISTRY" | while IFS=$'\t' read -r NAME P DATE; do
    MARKER=""
    [ "$NAME" = "$WORKTREE_NAME" ] && MARKER=" <-- current"
    printf "  %-25s %-8s %s%s\n" "$NAME" "$P" "$DATE" "$MARKER"
  done
fi
echo ""
