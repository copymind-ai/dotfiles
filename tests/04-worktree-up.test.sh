#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}04 — dev wt up (first worktree)${RESET}\n"

# ── Create .env.local in main so it gets copied ──────────────────────

touch "$TEST_DIR/main/.env.local"

# ── Create feat-alpha ─────────────────────────────────────────────────

header "dev wt up feat-alpha"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-up.sh" feat-alpha 2>&1) || true

assert_file_exists "worktree directory created" "$TEST_DIR/feat-alpha"
assert_file_exists "has supabase config" "$TEST_DIR/feat-alpha/supabase/config.toml"
assert "branch exists" git -C "$TEST_DIR/repo.git" show-ref --verify --quiet "refs/heads/feat-alpha"

# Verify worktree is listed
WT_LIST=$(cd "$TEST_DIR/repo.git" && git worktree list)
assert_contains "worktree listed" "feat-alpha" "$WT_LIST"

# ── Port registry ────────────────────────────────────────────────────

header "port registry"
REGISTRY="$TEST_DIR/.worktree-ports"

assert_file_exists "registry created" "$REGISTRY"
assert_contains "main registered" "main" "$(cat "$REGISTRY")"
assert_contains "feat-alpha registered" "feat-alpha" "$(cat "$REGISTRY")"

# Parse ports
MAIN_PORT=$(grep "^main	" "$REGISTRY" | awk -F'\t' '{print $2}')
ALPHA_PORT=$(grep "^feat-alpha	" "$REGISTRY" | awk -F'\t' '{print $2}')
assert_eq "main port is 13000" "13000" "$MAIN_PORT"
assert_eq "feat-alpha port is 13001" "13001" "$ALPHA_PORT"

# ── Generated files ──────────────────────────────────────────────────

header "generated files"

# .env with COMPOSE_PROJECT_NAME
assert_file_exists ".env exists" "$TEST_DIR/feat-alpha/.env"
COMPOSE_NAME=$(cat "$TEST_DIR/feat-alpha/.env")
assert_contains "COMPOSE_PROJECT_NAME set" "COMPOSE_PROJECT_NAME=" "$COMPOSE_NAME"
assert_contains "includes repo name" "feat-alpha" "$COMPOSE_NAME"

# docker-compose.override.yml with correct port
assert_file_exists "override.yml exists" "$TEST_DIR/feat-alpha/docker-compose.override.yml"
OVERRIDE=$(cat "$TEST_DIR/feat-alpha/docker-compose.override.yml")
assert_contains "override has port 13001" "13001:3000" "$OVERRIDE"

# .env.local copied/created
assert_file_exists ".env.local exists" "$TEST_DIR/feat-alpha/.env.local"

# ── Supabase hint ─────────────────────────────────────────────────────

header "supabase hints in output"
assert_contains "hints dev sb up" "dev sb up" "$OUTPUT"
assert_contains "hints dev wt env" "dev wt env" "$OUTPUT"

print_results
