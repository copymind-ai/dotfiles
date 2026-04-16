#!/usr/bin/env bash
set -euo pipefail

# Self-contained integration test for the migration hub.
# Creates a temporary bare repo, starts Supabase, runs all tests, cleans up.
#
# Usage: ./tests/test-migration-hub.sh
#
# Prerequisites: git, supabase CLI, docker, jq
# Note: Supabase must NOT be running — the test starts its own instance.

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"
TEST_DIR="/tmp/dotfiles-migration-hub-test-$$"
SUPABASE_STARTED=false

# ── Colors & helpers ──────────────────────────────────────────────────

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

PASSED=0
FAILED=0
CURRENT_TEST=""

header() {
  echo ""
  printf "${BOLD}── Test %s ──${RESET}\n" "$1"
  CURRENT_TEST="$1"
}

assert() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s\n" "$label"
  fi
}

assert_output_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected: %s\n" "$label" "$needle"
  fi
}

assert_output_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — unexpected: %s\n" "$label" "$needle"
  else
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  fi
}

assert_file_exists() {
  local label="$1"
  local path="$2"
  if [ -e "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — not found: %s\n" "$label" "$path"
  fi
}

assert_file_not_exists() {
  local label="$1"
  local path="$2"
  if [ ! -e "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — should not exist: %s\n" "$label" "$path"
  fi
}

assert_symlink_count() {
  local label="$1"
  local expected="$2"
  local dir="$3"
  local actual
  actual=$(find "$dir" -type l 2>/dev/null | wc -l | tr -d ' ')
  if [ "$actual" = "$expected" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s (count: %s)\n" "$label" "$actual"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected %s, got %s\n" "$label" "$expected" "$actual"
  fi
}

db_query() {
  docker exec -e PGPASSWORD=postgres supabase_db_test-mh \
    psql -U supabase_admin -d postgres -tAc "$1" 2>/dev/null
}

db_version_exists() {
  local version="$1"
  local count
  count=$(db_query "SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version = '$version';")
  [ "$count" = "1" ]
}

db_version_not_exists() {
  local version="$1"
  local count
  count=$(db_query "SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version = '$version';")
  [ "$count" = "0" ]
}

db_table_exists() {
  local table="$1"
  local count
  count=$(db_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table';")
  [ "$count" = "1" ]
}

# ── Cleanup ───────────────────────────────────────────────────────────

cleanup() {
  echo ""
  printf "${DIM}Cleaning up...${RESET}\n"

  if [ "$SUPABASE_STARTED" = true ] && [ -d "$TEST_DIR/main" ]; then
    (cd "$TEST_DIR/main" && supabase stop 2>/dev/null) || true
  fi

  if [ -d "$TEST_DIR" ]; then
    # Remove worktrees first (git complains if you delete them raw)
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
  printf "${BOLD}Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASSED" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then
    exit 1
  fi
}
trap cleanup EXIT

# ── Prerequisites ─────────────────────────────────────────────────────

echo ""
printf "${BOLD}Migration Hub — Integration Tests${RESET}\n"
echo ""

printf "${DIM}Checking prerequisites...${RESET}\n"
for cmd in git supabase docker jq; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required but not found."; exit 1; }
  printf "  ${GREEN}✓${RESET} %s\n" "$cmd"
done

# Verify scripts exist
for script in dev-worktree-migrate.sh dev-worktree-supabase.sh dev-worktree-up.sh dev-worktree-down.sh dev-worktree-env.sh dev-supabase.sh dev-worktree.sh; do
  [ -x "$SCRIPTS_DIR/$script" ] || { echo "Error: $SCRIPTS_DIR/$script not found or not executable."; exit 1; }
done
printf "  ${GREEN}✓${RESET} all scripts found\n"

# Note: test uses ports 54421/54422 so it can run alongside a real Supabase instance (54321/54322).

# ── Setup test repo ──────────────────────────────────────────────────

echo ""
printf "${DIM}Setting up test repo at %s...${RESET}\n" "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Create initial repo with content
INIT_DIR="$TEST_DIR/_init"
mkdir -p "$INIT_DIR"
cd "$INIT_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# ── Minimal project structure ──
mkdir -p supabase/migrations/app supabase/migrations/jobs scripts src

# supabase/config.toml — use test-mh project_id and offset all ports by +100
# to avoid conflicts with any running Supabase instance.
cat > supabase/config.toml << 'TOML'
project_id = "test-mh"

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

# scripts/db-migrate-local.sh — flattens app/+jobs/ then applies
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

# Initial migration — establishes the base
cat > supabase/migrations/app/20260101000000_init.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public._test_init (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

# docker-compose.yml — needed by dev-worktree-up.sh for port reading
cat > docker-compose.yml << 'YAML'
services:
  app:
    image: alpine:latest
    command: ["sleep", "infinity"]
    ports:
      - "13000:3000"
YAML

# Minimal src/ file so dev-worktree-env.sh has something to scan
mkdir -p src/lib
cat > src/lib/env.ts << 'TS'
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
TS

git add -A
git commit -q -m "initial structure"

# Clone as bare repo
cd "$TEST_DIR"
git clone -q --bare "$INIT_DIR" repo.git
rm -rf "$INIT_DIR"

# Create the "main" worktree
cd repo.git
git config user.email "test@test.com"
git config user.name "Test"

# Point origin at the bare repo itself so `git fetch origin` works
# (the real origin was the deleted _init dir)
git remote set-url origin "$TEST_DIR/repo.git"
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
# Create origin/main ref
git fetch -q origin 2>/dev/null || true

git worktree add -q "$TEST_DIR/main" main 2>/dev/null || git worktree add -q "$TEST_DIR/main" -b main HEAD
cd "$TEST_DIR/main"

printf "  ${GREEN}✓${RESET} test repo ready\n"

# ── Start Supabase ───────────────────────────────────────────────────

echo ""
printf "${DIM}Starting Supabase (this may take a minute on first run)...${RESET}\n"
cd "$TEST_DIR/main"
supabase start 2>&1 | tail -5
SUPABASE_STARTED=true
printf "  ${GREEN}✓${RESET} Supabase running\n"

# Apply initial migration
./scripts/db-migrate-local.sh 2>&1 | tail -3
printf "  ${GREEN}✓${RESET} initial migration applied\n"

# ═══════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════

# -------------------------------------------------------------------
header "1: dev wt sb — supabase worktree setup"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-supabase.sh" 2>&1) || true

assert_output_contains "prints 'Supabase hub ready'" "Supabase hub ready" "$OUTPUT"
assert_file_exists "supabase wt created" "$TEST_DIR/supabase"
assert_file_exists "supabase wt has config.toml" "$TEST_DIR/supabase/supabase/config.toml"

# Idempotent re-run
OUTPUT2=$("$SCRIPTS_DIR/dev-worktree-supabase.sh" 2>&1) || true
assert_output_contains "idempotent: 'Updating supabase worktree'" "Updating supabase worktree" "$OUTPUT2"
assert_output_contains "idempotent: 'up to date'" "up to date" "$OUTPUT2"

# -------------------------------------------------------------------
header "2: dev wt up — create feature worktree (test-alpha)"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-up.sh" test-alpha 2>&1) || true

assert_output_contains "refreshes migration hub" "Refreshing migration hub" "$OUTPUT"
assert_output_contains "hub refreshed" "Migration hub refreshed" "$OUTPUT"
assert_output_not_contains "no symlinking during wt up" "Symlinked" "$OUTPUT"
assert_file_exists "test-alpha worktree created" "$TEST_DIR/test-alpha/supabase/config.toml"
assert_symlink_count "no symlinks in hub yet" "0" "$TEST_DIR/supabase/supabase/migrations"

# -------------------------------------------------------------------
header "3: dev sb migrate — no new migrations"
# -------------------------------------------------------------------
cd "$TEST_DIR/test-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "reports no new migrations" "No new migrations in test-alpha" "$OUTPUT"
assert_symlink_count "still no symlinks" "0" "$TEST_DIR/supabase/supabase/migrations"

# -------------------------------------------------------------------
header "4: dev sb migrate — with a new migration"
# -------------------------------------------------------------------
cd "$TEST_DIR/test-alpha"

cat > supabase/migrations/app/20260418000001_test_alpha.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "found new migrations" "Found new migrations in test-alpha" "$OUTPUT"
assert_output_contains "symlinked 1" "Symlinked 1 migration" "$OUTPUT"
assert_output_contains "migration applied" "Applying migration 20260418000001" "$OUTPUT"
assert_file_exists "symlink created" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "symlink points to test-alpha" test -L "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "table created in DB" db_table_exists "test_alpha"

# -------------------------------------------------------------------
header "5: dev sb migrate — idempotent re-run"
# -------------------------------------------------------------------
cd "$TEST_DIR/test-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "no new migrations on re-run" "No new migrations in test-alpha" "$OUTPUT"
assert_output_not_contains "no symlinking on re-run" "Symlinked" "$OUTPUT"
assert_output_not_contains "no removal on re-run" "Removed" "$OUTPUT"

# -------------------------------------------------------------------
header "6: dev sb migrate — second migration in same worktree"
# -------------------------------------------------------------------
cd "$TEST_DIR/test-alpha"

cat > supabase/migrations/app/20260418000002_test_alpha_2.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha_2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "found new migration" "Found new migrations" "$OUTPUT"
assert_output_contains "symlinked only 1" "Symlinked 1 migration" "$OUTPUT"
assert_file_exists "first symlink still exists" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_file_exists "second symlink created" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "2 symlinks total" "2" "$TEST_DIR/supabase/supabase/migrations"
assert "second table created in DB" db_table_exists "test_alpha_2"

# -------------------------------------------------------------------
header "7: Multiple worktrees — second worktree (test-beta)"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
"$SCRIPTS_DIR/dev-worktree-up.sh" test-beta >/dev/null 2>&1 || true

cd "$TEST_DIR/test-beta"

cat > supabase/migrations/app/20260418000003_test_beta.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_beta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "symlinked test-beta migration" "Symlinked 1 migration" "$OUTPUT"
assert_symlink_count "3 symlinks total (2 alpha + 1 beta)" "3" "$TEST_DIR/supabase/supabase/migrations"
assert "test-beta table created" db_table_exists "test_beta"

# Verify symlinks point to correct worktrees
ALPHA_COUNT=$(find "$TEST_DIR/supabase/supabase/migrations" -type l -exec readlink {} \; | grep -c "test-alpha" || true)
BETA_COUNT=$(find "$TEST_DIR/supabase/supabase/migrations" -type l -exec readlink {} \; | grep -c "test-beta" || true)
assert "2 symlinks point to test-alpha" test "$ALPHA_COUNT" = "2"
assert "1 symlink points to test-beta" test "$BETA_COUNT" = "1"

# -------------------------------------------------------------------
header "8: Timestamp conflict detection"
# -------------------------------------------------------------------
cd "$TEST_DIR/test-beta"

cat > supabase/migrations/app/20250101000001_test_outdated.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_outdated (id uuid PRIMARY KEY);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert "exits with code 1" test "$EXIT_CODE" = "1"
assert_output_contains "reports outdated timestamps" "outdated timestamps" "$OUTPUT"
assert_output_contains "shows fix instruction" "Fix: rebase test-beta" "$OUTPUT"
assert_file_not_exists "outdated migration NOT symlinked" "$TEST_DIR/supabase/supabase/migrations/app/20250101000001_test_outdated.sql"
assert_file_exists "valid test-beta migration still intact" "$TEST_DIR/supabase/supabase/migrations/app/20260418000003_test_beta.sql"
assert_symlink_count "still 3 symlinks (no change)" "3" "$TEST_DIR/supabase/supabase/migrations"

# Cleanup the outdated file
rm "$TEST_DIR/test-beta/supabase/migrations/app/20250101000001_test_outdated.sql"

# -------------------------------------------------------------------
header "9: dev wt down — teardown test-alpha"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" test-alpha 2>&1) || true

assert_output_contains "removed 2 symlinks" "Removed 2 symlink" "$OUTPUT"
assert_output_contains "repairing migration history" "Repairing migration history" "$OUTPUT"
assert_output_contains "DB rows deleted" "DELETE 2" "$OUTPUT"
assert_file_not_exists "alpha symlink 1 gone" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_file_not_exists "alpha symlink 2 gone" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_file_exists "beta symlink still intact" "$TEST_DIR/supabase/supabase/migrations/app/20260418000003_test_beta.sql"
assert_symlink_count "1 symlink remains" "1" "$TEST_DIR/supabase/supabase/migrations"
assert "alpha version 1 removed from DB" db_version_not_exists "20260418000001"
assert "alpha version 2 removed from DB" db_version_not_exists "20260418000002"
assert "beta version still in DB" db_version_exists "20260418000003"
assert_output_not_contains "no migration errors" "Remote migration versions not found" "$OUTPUT"

# -------------------------------------------------------------------
header "10: dev wt down — teardown test-beta"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" test-beta 2>&1) || true

assert_output_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_output_contains "DB row deleted" "DELETE 1" "$OUTPUT"
assert_symlink_count "no symlinks remain" "0" "$TEST_DIR/supabase/supabase/migrations"
assert_output_not_contains "no migration errors" "Remote migration versions not found" "$OUTPUT"

# -------------------------------------------------------------------
header "11: dev sb migrate from main — post-cleanup sanity"
# -------------------------------------------------------------------
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_output_contains "no new migrations" "No new migrations in main" "$OUTPUT"
assert_output_contains "DB up to date" "up to date" "$OUTPUT"

echo ""
printf "${BOLD}All tests complete.${RESET}\n"
