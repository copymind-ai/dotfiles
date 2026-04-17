#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}12 — Worktree init (bootstrap)${RESET}\n"

# ── Rejects non-bare repo ──────────────────────────────────────────

header "rejects non-bare repo"
setup_tmpdir
cd "$TEST_TMPDIR"
git init -q test-repo && cd test-repo
git config user.email "test@test.com" && git config user.name "Test"
touch file && git add file && git commit -q -m "init"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "mentions bare" "bare" "$OUTPUT"

# ── Rejects when worktrees already exist ────────────────────────────

header "rejects when worktrees already exist"
setup_tmpdir
cd "$TEST_TMPDIR"
git init -q init-repo && cd init-repo
git config user.email "test@test.com" && git config user.name "Test"
cat > docker-compose.yml << 'YAML'
services:
  app:
    ports:
      - "3000:3000"
YAML
git add -A && git commit -q -m "init"

cd "$TEST_TMPDIR"
git clone -q --bare init-repo repo.git
cd repo.git
git config user.email "test@test.com" && git config user.name "Test"
git remote set-url origin "$TEST_TMPDIR/repo.git"
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch -q origin 2>/dev/null || true
git worktree add -q "$TEST_TMPDIR/existing-wt" main

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "mentions already exists" "already" "$OUTPUT"

# ── Creates first worktree successfully ──────────────────────────────

header "creates first worktree from bare repo"
setup_tmpdir
cd "$TEST_TMPDIR"
git init -q init-repo2 && cd init-repo2
git config user.email "test@test.com" && git config user.name "Test"
cat > docker-compose.yml << 'YAML'
services:
  app:
    ports:
      - "4000:3000"
YAML
git add -A && git commit -q -m "init"

cd "$TEST_TMPDIR"
git clone -q --bare init-repo2 repo.git
cd repo.git
git config user.email "test@test.com" && git config user.name "Test"
git remote set-url origin "$TEST_TMPDIR/repo.git"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1)
assert "exits successfully" true
assert_contains "shows worktree path" "main" "$OUTPUT"
assert_file_exists "worktree directory created" "$TEST_TMPDIR/main"
assert_file_exists "docker-compose.yml present" "$TEST_TMPDIR/main/docker-compose.yml"

# ── Port registry initialized ───────────────────────────────────────

header "port registry initialized"
assert_file_exists "registry file created" "$TEST_TMPDIR/.worktree-ports"

REGISTRY_CONTENT=$(cat "$TEST_TMPDIR/.worktree-ports")
assert_contains "registry has header" "worktree" "$REGISTRY_CONTENT"
assert_contains "registry has main entry" "main" "$REGISTRY_CONTENT"
assert_contains "registry has base port" "4000" "$REGISTRY_CONTENT"

# ── Prints next steps ───────────────────────────────────────────────

header "prints next steps"
assert_contains "mentions cd" "cd" "$OUTPUT"
assert_contains "mentions dev wt up" "dev wt up" "$OUTPUT"

print_results
