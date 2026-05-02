#!/usr/bin/env bash
set -euo pipefail

# Anchor the shared Supabase edge runtime to the current worktree's app port.
#
# Why this exists: the edge runtime container bakes COPYMIND_API_HOST in at
# creation time (Docker copies env vars from `supabase start`'s environment
# into the container's config). When workers post back to the app
# (/api/job, /api/chat/...) they use that baked-in URL — so if the shared
# Supabase stack was started against a different worktree's port, every
# pgflow worker call ECONNREFUSEs against the wrong host port.
#
# This script:
#   1. Reads the invoking worktree's port from .worktree-ports.
#   2. Rewrites COPYMIND_API_HOST in the shared supabase worktree's
#      .env.local (preserving every other line).
#   3. If the value actually changed, cycles the whole Supabase stack
#      (`supabase stop` + `supabase start`) so the edge runtime container
#      is recreated with the new env baked in. A partial restart is not
#      enough — `supabase start` against a half-up stack short-circuits
#      with "already running" and never recreates the container.
#
# Usage: dev sb anchor   (run from the worktree you want to anchor to)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

INVOKING_WT="$(git rev-parse --show-toplevel)"
WORKTREE_NAME="$(basename "$INVOKING_WT")"
PARENT_DIR="$(cd "$INVOKING_WT/.." && pwd)"
REGISTRY="$PARENT_DIR/.worktree-ports"
SHARED_WT="$PARENT_DIR/supabase"

# ── Resolve invoking worktree's port ─────────────────────────────────
if [ ! -f "$REGISTRY" ]; then
  echo "Error: Port registry not found at $REGISTRY" >&2
  echo "  Fix: run 'dev wt init' from the bare repo to bootstrap the registry." >&2
  exit 1
fi

APP_PORT="$(awk -F'\t' -v n="$WORKTREE_NAME" '$1 == n {print $2; exit}' "$REGISTRY")"
if [ -z "$APP_PORT" ]; then
  echo "Error: No entry for worktree '$WORKTREE_NAME' in $REGISTRY" >&2
  echo "  Fix: re-create this worktree with 'dev wt up <branch>', or add a row manually." >&2
  exit 1
fi

# ── Locate shared supabase worktree ──────────────────────────────────
if [ ! -d "$SHARED_WT" ] || [ ! -f "$SHARED_WT/supabase/config.toml" ]; then
  echo "Error: Shared supabase worktree not found at $SHARED_WT" >&2
  echo "  Fix: run 'dev sb up' to create it." >&2
  exit 1
fi

ENV_FILE="$SHARED_WT/.env.local"
NEW_VALUE="http://host.docker.internal:${APP_PORT}"

# ── Rewrite COPYMIND_API_HOST in shared .env.local ───────────────────
# upsert_env preserves every other line and handles both "key already
# present" and "key missing" with a single sed/append branch.
touch "$ENV_FILE"
CURRENT_VALUE="$(awk -F= -v k="COPYMIND_API_HOST" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
upsert_env "$ENV_FILE" "COPYMIND_API_HOST" "$NEW_VALUE"
echo "==> Anchored shared Supabase to '$WORKTREE_NAME' (port $APP_PORT)"
echo "    $ENV_FILE: COPYMIND_API_HOST=$NEW_VALUE"

# ── Recreate edge runtime container (only if env actually changed) ───
# Skipping the cycle when the value is already correct keeps re-running
# `dev sb anchor` cheap (the cycle takes ~10s and drops every connection
# the user's currently-running workers hold).
if [ "$CURRENT_VALUE" = "$NEW_VALUE" ]; then
  echo "    (env unchanged — skipping stack cycle)"
else
  # `supabase stop` and `supabase start` are run as separate statements,
  # not chained with `&&`: under `set -e` a non-zero stop (e.g. stack
  # already down, half-up state) would otherwise skip start entirely.
  # `|| true` on stop swallows the "nothing to stop" case; start is left
  # to fail loudly because we genuinely need it to succeed.
  echo "==> Cycling Supabase stack to recreate edge runtime with new env"
  (
    cd "$SHARED_WT"
    supabase stop >/dev/null 2>&1 || true
    supabase start >/dev/null
  )
  # `supabase stop` orphans the host-side `supabase functions serve`
  # process and the ControlPlane endpoint depends on it, so respawn.
  ensure_functions_serve "$SHARED_WT"

  API_PORT="$(get_api_port "$SHARED_WT")"
  wait_for_control_plane "$API_PORT" || {
    echo "Warning: ControlPlane did not come up within timeout — workers may need a moment." >&2
  }
fi

echo ""
echo "Done. pgflow workers will now post to $NEW_VALUE."
