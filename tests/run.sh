#!/usr/bin/env bash
set -euo pipefail

# Unified test runner: sets up a bare repo + real Supabase, runs all tests, cleans up.
#
# Usage: ./tests/run.sh [pattern]
# Examples:
#   ./tests/run.sh              # run all
#   ./tests/run.sh migrate      # run only *migrate* tests
#   ./tests/run.sh unit         # run only *unit* tests

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ── Colors (reuse from helpers) ──────────────────────────────────────

TEST_DIR="/tmp/dotfiles-test-suite-$$"
TEST_DB_CONTAINER="supabase_db_test-int"
export TEST_DIR TEST_DB_CONTAINER SCRIPTS_DIR RUN_FROM_RUNNER=1

PATTERN="${1:-}"
SUPABASE_STARTED=false
FAILED_TESTS=()
STATS_FILE=""

# ── Cleanup ──────────────────────────────────────────────────────────

cleanup() {
  echo ""
  printf "${DIM}Cleaning up...${RESET}\n"

  if [ "$SUPABASE_STARTED" = true ] && [ -d "$TEST_DIR/main" ]; then
    (cd "$TEST_DIR/main" && supabase stop 2>/dev/null) || true
  fi

  # Aggregate stats before removing TEST_DIR
  local total_passed=0 total_failed=0
  if [ -f "${STATS_FILE:-}" ]; then
    while read -r p f; do
      total_passed=$((total_passed + p))
      total_failed=$((total_failed + f))
    done < "$STATS_FILE"
  fi

  if [ -d "$TEST_DIR" ]; then
    if [ -d "$TEST_DIR/repo.git" ]; then
      cd "$TEST_DIR/repo.git"
      git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10) }' | while read -r wt; do
        [ "$wt" = "$TEST_DIR/repo.git" ] && continue
        git worktree remove "$wt" --force 2>/dev/null || true
      done
    fi
    rm -rf "$TEST_DIR"
  fi

  echo ""
  printf "${BOLD}Total: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$total_passed" "$total_failed"

  if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo ""
    printf "${RED}${BOLD}Failed test files:${RESET}\n"
    for f in "${FAILED_TESTS[@]}"; do
      printf "  ${RED}✗${RESET} %s\n" "$f"
    done
    exit 1
  else
    printf "${GREEN}${BOLD}All tests passed.${RESET}\n"
  fi
}
trap cleanup EXIT

# ── Prerequisites ────────────────────────────────────────────────────

echo ""
printf "${BOLD}Dev CLI — Unified Test Suite${RESET}\n"
echo ""

printf "${DIM}Checking prerequisites...${RESET}\n"
for cmd in git supabase docker jq; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required but not found."; exit 1; }
  printf "  ${GREEN}✓${RESET} %s\n" "$cmd"
done

for script in dev.sh dev-worktree.sh dev-supabase.sh dev-worktree-up.sh dev-worktree-down.sh dev-worktree-info.sh dev-worktree-env.sh dev-worktree-migrate.sh dev-session.sh; do
  [ -x "$SCRIPTS_DIR/$script" ] || { echo "Error: $SCRIPTS_DIR/$script not found or not executable."; exit 1; }
done
printf "  ${GREEN}✓${RESET} all scripts found\n"

# ── Setup test repo ─────────────────────────────────────────────────

echo ""
printf "${DIM}Setting up test repo at %s...${RESET}\n" "$TEST_DIR"
mkdir -p "$TEST_DIR"
STATS_FILE="$TEST_DIR/.test-stats"
export STATS_FILE

INIT_DIR="$TEST_DIR/_init"
mkdir -p "$INIT_DIR"
cd "$INIT_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# ── Minimal project structure ──
mkdir -p supabase/migrations/app supabase/migrations/jobs scripts src/lib

cat > supabase/config.toml << 'TOML'
project_id = "test-int"

[api]
enabled = true
port = 54421
schemas = ["public"]
extra_search_path = ["public"]

[db]
port = 54422
shadow_port = 54420
major_version = 17

[db.pooler]
enabled = false

[studio]
enabled = false

[inbucket]
enabled = false

[storage]
enabled = true

[auth]
enabled = true

[edge_runtime]
enabled = false

[analytics]
enabled = false
TOML

cat > scripts/db-migrate-local.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
MIGRATIONS_DIR="supabase/migrations"
TEMP_DIR="${MIGRATIONS_DIR}_flat"
mkdir -p "$TEMP_DIR"
for PROJECT_DIR in "$MIGRATIONS_DIR"/*/; do
  cp "$PROJECT_DIR"*.sql "$TEMP_DIR/" 2>/dev/null || true
done
mv "$MIGRATIONS_DIR" "${MIGRATIONS_DIR}_split"
mv "$TEMP_DIR" "$MIGRATIONS_DIR"
cleanup() {
  rm -rf "$MIGRATIONS_DIR"
  mv "${MIGRATIONS_DIR}_split" "$MIGRATIONS_DIR"
}
trap cleanup EXIT
supabase migration up --db-url "postgresql://supabase_admin:postgres@127.0.0.1:54422/postgres"
SCRIPT
chmod +x scripts/db-migrate-local.sh

cat > supabase/migrations/app/20260101000000_init.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public._test_init (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

cat > docker-compose.yml << 'YAML'
services:
  app:
    image: alpine:latest
    command: ["sleep", "infinity"]
    ports:
      - "13000:3000"
YAML

cat > src/lib/env.ts << 'TS'
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
TS

git add -A
git commit -q -m "initial structure"

# Clone as bare repo
cd "$TEST_DIR"
git clone -q --bare "$INIT_DIR" repo.git
rm -rf "$INIT_DIR"

cd repo.git
git config user.email "test@test.com"
git config user.name "Test"
git remote set-url origin "$TEST_DIR/repo.git"
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch -q origin 2>/dev/null || true

git worktree add -q "$TEST_DIR/main" main 2>/dev/null || git worktree add -q "$TEST_DIR/main" -b main HEAD
cd "$TEST_DIR/main"

printf "  ${GREEN}✓${RESET} test repo ready\n"

# ── Start Supabase ───────────────────────────────────────────────────

echo ""
printf "${DIM}Starting Supabase (this may take a minute on first run)...${RESET}\n"
cd "$TEST_DIR/main"
# Stop any leftover containers and delete volumes from a previous run
supabase stop --no-backup 2>/dev/null || true
supabase start 2>&1 | tail -5
SUPABASE_STARTED=true
printf "  ${GREEN}✓${RESET} Supabase running\n"

./scripts/db-migrate-local.sh 2>&1 | tail -3
printf "  ${GREEN}✓${RESET} initial migration applied\n"

# ── Run tests ────────────────────────────────────────────────────────

for test_file in "$TESTS_DIR"/[0-9]*.test.sh; do
  [ -f "$test_file" ] || continue

  if [ -n "$PATTERN" ] && [[ "$(basename "$test_file")" != *"$PATTERN"* ]]; then
    continue
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "Running: %s\n" "$(basename "$test_file")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Run test file in the same shell context (shared TEST_DIR state)
  if bash "$test_file"; then
    : # test passed
  else
    FAILED_TESTS+=("$(basename "$test_file")")
  fi
done
