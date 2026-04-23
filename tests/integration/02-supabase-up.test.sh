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

# ── Edge functions started by dev sb up ──────────────────────────────
# pgflow's ensure_workers cron needs the edge runtime up to dispatch
# flow tasks. Previously only `dev sb reset` started it, which was the
# gap that made unreleased flows silently fail to run after `dev sb up`.

header "dev sb up — edge functions started"
assert_contains "starts edge functions" "Starting edge functions" "$OUTPUT"

# The backgrounded `supabase functions serve` process spawns the edge
# runtime container asynchronously. Poll briefly instead of a blind sleep.
EDGE_CONTAINER="supabase_edge_runtime_test-int"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1 && break
  sleep 1
done

if pgrep -f 'supabase functions serve' >/dev/null 2>&1; then
  PASSED=$((PASSED + 1))
  printf "  ${GREEN}✓${RESET} functions serve process running\n"
else
  FAILED=$((FAILED + 1))
  printf "  ${RED}✗${RESET} functions serve process not running\n"
fi

if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
  PASSED=$((PASSED + 1))
  printf "  ${GREEN}✓${RESET} edge runtime container running\n"
else
  FAILED=$((FAILED + 1))
  printf "  ${RED}✗${RESET} edge runtime container '$EDGE_CONTAINER' not running\n"
fi

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-up.sh" 2>&1) || true

assert_contains "updates worktree" "Updating supabase worktree" "$OUTPUT"
assert_contains "already running" "already running" "$OUTPUT"
assert_contains "detects existing edge functions" "Edge functions already running" "$OUTPUT"

# Kill the backgrounded functions serve so test 03 starts from a clean slate
# (matches the cleanup pattern used after 03-db-reset.test.sh's own checks).
pkill -f 'supabase functions serve' 2>/dev/null || true

print_results
