#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}03 — dev sb up (Supabase worktree setup)${RESET}\n"

# ── First run — creates supabase worktree ────────────────────────────

header "creates supabase worktree"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase.sh" up 2>&1) || true

assert_contains "prints hub ready" "Supabase hub ready" "$OUTPUT"
assert_file_exists "supabase worktree created" "$TEST_DIR/supabase"
assert_file_exists "has config.toml" "$TEST_DIR/supabase/supabase/config.toml"
assert_contains "shows worktree path" "$TEST_DIR/supabase" "$OUTPUT"

# Verify it's detached at origin/main
SUPABASE_HEAD=$(cd "$TEST_DIR/supabase" && git rev-parse HEAD)
ORIGIN_MAIN=$(cd "$TEST_DIR/repo.git" && git rev-parse origin/main)
assert_eq "detached at origin/main" "$ORIGIN_MAIN" "$SUPABASE_HEAD"

# ── Idempotent re-run ────────────────────────────────────────────────

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase.sh" up 2>&1) || true

assert_contains "updates existing worktree" "Updating supabase worktree" "$OUTPUT"
assert_contains "supabase already running" "already running" "$OUTPUT"

print_results
