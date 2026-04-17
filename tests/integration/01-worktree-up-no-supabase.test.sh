#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#1 — dev wt up (Supabase not running)${RESET}\n"

# Supabase is NOT running (runner doesn't start it)

header "dev wt up feat-alpha"
cd "$TEST_DIR/main"
touch "$TEST_DIR/main/.env.local"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-up.sh" feat-alpha 2>&1) || true

assert_file_exists "worktree created" "$TEST_DIR/feat-alpha"
assert_file_exists "has supabase config" "$TEST_DIR/feat-alpha/supabase/config.toml"
assert "branch exists" git -C "$TEST_DIR/repo.git" show-ref --verify --quiet "refs/heads/feat-alpha"

# Port registry
REGISTRY="$TEST_DIR/.worktree-ports"
assert_file_exists "registry created" "$REGISTRY"
ALPHA_PORT=$(grep "^feat-alpha	" "$REGISTRY" | awk -F'\t' '{print $2}')
assert_eq "feat-alpha port is 13001" "13001" "$ALPHA_PORT"

# Generated files
assert_file_exists ".env exists" "$TEST_DIR/feat-alpha/.env"
assert_contains "COMPOSE_PROJECT_NAME" "COMPOSE_PROJECT_NAME=" "$(cat "$TEST_DIR/feat-alpha/.env")"
assert_file_exists "override.yml exists" "$TEST_DIR/feat-alpha/docker-compose.override.yml"
assert_contains "port 13001" "13001:3000" "$(cat "$TEST_DIR/feat-alpha/docker-compose.override.yml")"

# Should NOT inject Supabase vars (not running)
assert_not_contains "no injection" "Injecting Supabase env vars" "$OUTPUT"

# Should show hints
assert_contains "hints dev sb up" "dev sb up" "$OUTPUT"
assert_contains "hints dev wt env" "dev wt env" "$OUTPUT"

print_results
