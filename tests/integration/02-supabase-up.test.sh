#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#2 — dev sb up${RESET}\n"

header "start supabase"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-up.sh" 2>&1) || true

assert_contains "supabase ready" "Supabase ready" "$OUTPUT"
assert_file_exists "supabase worktree created" "$WORKTREE_BASE/supabase"
assert_file_exists "has config.toml" "$WORKTREE_BASE/supabase/supabase/config.toml"

# Verify detached at origin/main
SUPABASE_HEAD=$(cd "$WORKTREE_BASE/supabase" && git rev-parse HEAD)
ORIGIN_MAIN=$(cd "$TEST_DIR/repo.git" && git rev-parse origin/main)
assert_eq "detached at origin/main" "$ORIGIN_MAIN" "$SUPABASE_HEAD"

# ── Edge runtime available after dev sb up ───────────────────────────
# pgflow's ensure_workers cron needs the edge runtime container up to
# dispatch flow tasks. Previously `dev sb up` would leave the shared
# worktree in a state where the container was missing on platforms
# where `supabase start` doesn't auto-spawn it (e.g. macOS Docker
# Desktop with certain edge_runtime policies). On Linux CI runners
# with Docker Engine, `supabase start` already spawns the container;
# either way, the container MUST be running after `dev sb up`.

header "dev sb up — edge runtime container running"
EDGE_CONTAINER="supabase_edge_runtime_test-int"
if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1 && \
   [ "$(docker inspect -f '{{.State.Running}}' "$EDGE_CONTAINER" 2>/dev/null)" = "true" ]; then
  PASSED=$((PASSED + 1))
  printf "  ${GREEN}✓${RESET} edge runtime container '$EDGE_CONTAINER' is running\n"
else
  FAILED=$((FAILED + 1))
  printf "  ${RED}✗${RESET} edge runtime container '$EDGE_CONTAINER' not running\n"
fi

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-up.sh" 2>&1) || true

assert_contains "updates worktree" "Updating supabase worktree" "$OUTPUT"
assert_contains "already running" "already running" "$OUTPUT"
# Re-run must detect the edge runtime container and not try to double-start.
# The message is printed by dev-supabase-up.sh when the container is already up.
assert_contains "detects existing edge runtime" "Edge functions already running" "$OUTPUT"

# Clean up any backgrounded `supabase functions serve` so later tests start
# from a predictable state (matches 03-db-reset's post-assertion pkill).
pkill -f 'supabase functions serve' 2>/dev/null || true

print_results
