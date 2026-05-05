#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}02 — Router dispatch${RESET}\n"

# ── dev.sh ───────────────────────────────────────────────────────────

header "dev.sh — no args"
OUTPUT=$(bash "$SCRIPTS_DIR/dev.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev" "$OUTPUT"
assert_contains "lists session" "session" "$OUTPUT"
assert_contains "lists supabase" "supabase" "$OUTPUT"
assert_contains "lists worktree" "worktree" "$OUTPUT"

header "dev.sh — unknown command"
OUTPUT=$(bash "$SCRIPTS_DIR/dev.sh" nonsense 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev" "$OUTPUT"

# ── dev-worktree.sh ──────────────────────────────────────────────────

header "dev-worktree.sh — no args"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev wt" "$OUTPUT"
assert_contains "lists init" "init" "$OUTPUT"
assert_contains "lists up" "up" "$OUTPUT"
assert_contains "lists down" "down" "$OUTPUT"
assert_contains "lists env" "env" "$OUTPUT"

header "dev-worktree.sh — unknown subcommand"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree.sh" nonsense 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"

# ── dev-supabase.sh ──────────────────────────────────────────────────

header "dev-supabase.sh — no args"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev supabase" "$OUTPUT"

# ── dev-supabase.sh subcommands ───────────────────────────────────────

header "dev-supabase.sh — lists all subcommands"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" 2>&1) || EXIT_CODE=$?
assert_contains "lists link" "link" "$OUTPUT"
assert_contains "lists unlink" "unlink" "$OUTPUT"
assert_contains "lists sync" "sync" "$OUTPUT"
assert_contains "lists anchor" "anchor" "$OUTPUT"

# ── Non-bare repo checks ────────────────────────────────────────────

header "non-bare repo checks"
setup_tmpdir
cd "$TEST_TMPDIR"
git init -q test-repo && cd test-repo
git config user.email "test@test.com" && git config user.name "Test"
touch file && git add file && git commit -q -m "init"

for script in dev-worktree-init.sh dev-worktree-up.sh dev-worktree-down.sh dev-worktree-info.sh; do
  OUTPUT=$(bash "$SCRIPTS_DIR/$script" test-branch 2>&1) || EXIT_CODE=$?
  assert_exit_code "$script rejects non-bare repo" "1" "${EXIT_CODE:-0}"
  assert_contains "$script mentions bare" "bare" "$OUTPUT"
done

OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" up 2>&1) || EXIT_CODE=$?
assert_exit_code "dev sb up rejects non-bare repo" "1" "${EXIT_CODE:-0}"
assert_contains "dev sb up mentions bare" "bare" "$OUTPUT"

# ── Missing branch arg checks ───────────────────────────────────────

header "missing branch argument"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-up.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "worktree-up requires branch" "1" "${EXIT_CODE:-0}"
assert_contains "worktree-up error message" "branch name is required" "$OUTPUT"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-down.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "worktree-down requires branch" "1" "${EXIT_CODE:-0}"
assert_contains "worktree-down error message" "branch name is required" "$OUTPUT"

# ── dev-env.sh ───────────────────────────────────────────────────────

header "dev.sh — lists env command"
OUTPUT=$(bash "$SCRIPTS_DIR/dev.sh" 2>&1) || EXIT_CODE=$?
assert_contains "lists env" "env" "$OUTPUT"

header "dev-env.sh — no args"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev env" "$OUTPUT"
assert_contains "lists add" "add" "$OUTPUT"
assert_contains "lists remove" "remove" "$OUTPUT"
assert_contains "lists pull" "pull" "$OUTPUT"
assert_contains "lists push" "push" "$OUTPUT"

header "dev-env.sh — unknown subcommand"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env.sh" nonsense 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "shows usage" "Usage: dev env" "$OUTPUT"

# ── dev-env-add.sh validation ───────────────────────────────────────

header "dev-env-add.sh — missing name"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-add.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "name required" "name is required" "$OUTPUT"

header "dev-env-add.sh — lowercase name rejected"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-add.sh" my_var 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "name regex error" "must match" "$OUTPUT"

header "dev-env-add.sh — leading-digit name rejected"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-add.sh" 1FOO 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "regex error for digits" "must match" "$OUTPUT"

header "dev-env-add.sh — --prod and --dev mutually exclusive"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-add.sh" --prod --dev FOO 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "mutually exclusive error" "mutually exclusive" "$OUTPUT"

header "dev-env-add.sh — unknown flag rejected"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-add.sh" --staging FOO 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "unknown flag error" "unknown flag" "$OUTPUT"

# ── dev-env-remove.sh validation ────────────────────────────────────

header "dev-env-remove.sh — missing name"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-remove.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "name required" "name is required" "$OUTPUT"

header "dev-env-remove.sh — --prod and --dev mutually exclusive"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-env-remove.sh" --prod --dev FOO 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "mutually exclusive error" "mutually exclusive" "$OUTPUT"

print_results
