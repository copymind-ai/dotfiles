#!/usr/bin/env bash
set -euo pipefail

# Test runner: sets up a bare repo fixture, runs all tests in order, cleans up.
# Tests are responsible for starting/stopping Supabase as needed.
#
# Usage: ./tests/run.sh [--unit|--integration|--e2e] [pattern]
# Examples:
#   ./tests/run.sh              # run all
#   ./tests/run.sh --unit       # unit tests only
#   ./tests/run.sh link         # only files matching *link*

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TESTS_DIR/helpers.sh"

TEST_DIR="/tmp/dotfiles-test-suite-$$"
WORKTREE_BASE="$TEST_DIR/repo.git"
TEST_DB_CONTAINER="supabase_db_test-int"
export TEST_DIR WORKTREE_BASE TEST_DB_CONTAINER SCRIPTS_DIR RUN_FROM_RUNNER=1

# Parse arguments
LAYER=""
PATTERN=""
for arg in "$@"; do
  case "$arg" in
    --unit)        LAYER="unit" ;;
    --integration) LAYER="integration" ;;
    --e2e)         LAYER="e2e" ;;
    *)             PATTERN="$arg" ;;
  esac
done

FAILED_TESTS=()
STATS_FILE=""

# ── Cleanup ──────────────────────────────────────────────────────────

cleanup() {
  echo ""
  printf "${DIM}Cleaning up...${RESET}\n"

  # Reap any backgrounded `supabase functions serve` processes started by
  # `dev sb reset` tests.
  pkill -f 'supabase functions serve' 2>/dev/null || true

  # Stop Supabase if running
  if [ -d "$WORKTREE_BASE/main" ]; then
    (cd "$WORKTREE_BASE/main" && supabase stop --no-backup 2>/dev/null) || true
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
printf "${BOLD}Dev CLI — Test Suite${RESET}\n"
echo ""

printf "${DIM}Checking prerequisites...${RESET}\n"
for cmd in git supabase docker jq psql rsync curl; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required but not found."; exit 1; }
  printf "  ${GREEN}✓${RESET} %s\n" "$cmd"
done
# pgflow: required for e2e test 04-db-flow-lifecycle. Install via ./install.sh
# (which handles node + `npm install -g pgflow`).
if ! command -v pgflow >/dev/null && ! npx -y pgflow --version >/dev/null 2>&1; then
  echo "Error: pgflow is required but not found. Run ./install.sh from the repo root."
  exit 1
fi
printf "  ${GREEN}✓${RESET} pgflow\n"
printf "  ${GREEN}✓${RESET} all scripts found\n"

# ── Setup bare repo fixture ─────────────────────────────────────────

echo ""
printf "${DIM}Setting up test repo at %s...${RESET}\n" "$TEST_DIR"
mkdir -p "$TEST_DIR"
STATS_FILE="$TEST_DIR/.test-stats"
export STATS_FILE

INIT_DIR="$TEST_DIR/_init"
mkdir -p "$INIT_DIR"
cd "$INIT_DIR"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"

mkdir -p supabase/migrations/app supabase/migrations/jobs supabase/seeds supabase/flows supabase/functions/pgflow src/lib src/types

cat > supabase/config.toml << 'TOML'
project_id = "test-int"

[api]
enabled = true
port = 54621
schemas = ["public"]
extra_search_path = ["public"]

[db]
port = 54622
shadow_port = 54620
major_version = 17

[db.pooler]
enabled = false

[db.seed]
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
enabled = true
policy = "oneshot"

[analytics]
enabled = false
TOML

cat > supabase/migrations/app/20260101000000_init.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public._test_init (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

# Minimal noop flow for `dev sb flow` end-to-end tests. The ControlPlane
# (edge runtime) resolves @pgflow/dsl via Deno's npm resolver, per deno.json.
cat > supabase/flows/noop.ts << 'TS'
import { Flow } from "@pgflow/dsl";

export const Noop = new Flow<{ value: string }>({
  slug: "noop",
}).step({ slug: "doNothing" }, (input) => ({ ok: true, value: input.run.value }));
TS

cat > supabase/flows/index.ts << 'TS'
export { Noop } from "./noop.ts";
TS

cat > supabase/functions/pgflow/deno.json << 'JSON'
{
  "imports": {
    "@pgflow/core": "npm:@pgflow/core@0.14.1",
    "@pgflow/core/": "npm:@pgflow/core@0.14.1/",
    "@pgflow/dsl": "npm:@pgflow/dsl@0.14.1",
    "@pgflow/dsl/": "npm:@pgflow/dsl@0.14.1/",
    "@pgflow/edge-worker": "jsr:@pgflow/edge-worker@0.14.1",
    "@pgflow/edge-worker/": "jsr:@pgflow/edge-worker@0.14.1/"
  }
}
JSON

cat > supabase/functions/pgflow/index.ts << 'TS'
import { ControlPlane } from "@pgflow/edge-worker";
import * as flows from "../../flows/index.ts";

ControlPlane.serve(flows);
TS

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

cd "$TEST_DIR"
git clone -q --bare "$INIT_DIR" repo.git
rm -rf "$INIT_DIR"

cd repo.git
git config user.email "test@test.com"
git config user.name "Test"
git remote set-url origin "$TEST_DIR/repo.git"

printf "  ${GREEN}✓${RESET} bare repo ready (integration/00 bootstraps via \`dev wt init\`)\n"

# ── Run tests ────────────────────────────────────────────────────────

run_layer() {
  local layer_name="$1"
  local layer_dir="$TESTS_DIR/$layer_name"
  [ -d "$layer_dir" ] || return 0

  local has_tests=false
  for f in "$layer_dir"/[0-9]*.test.sh; do
    [ -f "$f" ] || continue
    if [ -n "$PATTERN" ] && [[ "$(basename "$f")" != *"$PATTERN"* ]]; then
      continue
    fi
    has_tests=true
    break
  done
  [ "$has_tests" = true ] || return 0

  echo ""
  printf "${BOLD}━━━ %s ━━━${RESET}\n" "$(echo "$layer_name" | tr '[:lower:]' '[:upper:]')"

  for test_file in "$layer_dir"/[0-9]*.test.sh; do
    [ -f "$test_file" ] || continue

    if [ -n "$PATTERN" ] && [[ "$(basename "$test_file")" != *"$PATTERN"* ]]; then
      continue
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "Running: %s/%s\n" "$layer_name" "$(basename "$test_file")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if bash "$test_file"; then
      : # test passed
    else
      FAILED_TESTS+=("$layer_name/$(basename "$test_file")")
    fi
  done
}

if [ -n "$LAYER" ]; then
  run_layer "$LAYER"
else
  run_layer "unit"
  run_layer "integration"
  run_layer "e2e"
fi
