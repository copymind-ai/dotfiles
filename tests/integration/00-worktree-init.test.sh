#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#0 — dev wt init (bootstrap)${RESET}\n"

header "dev wt init from fresh bare clone"
cd "$TEST_DIR/repo.git"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1) || true

assert_file_exists "main worktree created" "$TEST_DIR/main"
assert_file_exists "worktree has docker-compose.yml" "$TEST_DIR/main/docker-compose.yml"
assert_file_exists "worktree has supabase config" "$TEST_DIR/main/supabase/config.toml"
assert_file_exists "port registry created" "$TEST_DIR/.worktree-ports"

REGISTRY_CONTENT=$(cat "$TEST_DIR/.worktree-ports")
assert_contains "registry has main entry" "main" "$REGISTRY_CONTENT"
assert_contains "registry has base port" "13000" "$REGISTRY_CONTENT"

assert_contains "prints next steps" "dev wt up" "$OUTPUT"

# Stop any leftover Supabase containers from previous test runs
(cd "$TEST_DIR/main" && supabase stop --no-backup 2>/dev/null) || true

print_results
