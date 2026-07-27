#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: Migration lifecycle${RESET}\n"

# At this point: feat-alpha + feat-beta exist, Supabase running, no migrations linked

# ── Link ─────────────────────────────────────────────────────────────

header "no new migrations initially"
cd "$WORKTREE_BASE/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "reports no new" "No new migrations in feat-alpha" "$OUTPUT"
assert_symlink_count "no symlinks in supabase wt" "0" "$WORKTREE_BASE/supabase/supabase/migrations"

header "new migration — symlink + apply"
cd "$WORKTREE_BASE/feat-alpha"
cat > supabase/migrations/app/20260418000001_test_alpha.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now()
);
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "found new" "Found new migrations in feat-alpha" "$OUTPUT"
assert_contains "symlinked 1" "Symlinked 1 migration" "$OUTPUT"
assert_symlink "symlink created" "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "table in DB" db_table_exists "test_alpha"

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "no new on re-run" "No new migrations in feat-alpha" "$OUTPUT"

header "second migration"
cat > supabase/migrations/app/20260418000002_test_alpha_2.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha_2 (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "symlinked only 1" "Symlinked 1 migration" "$OUTPUT"
assert_symlink_count "2 symlinks total" "2" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "second table in DB" db_table_exists "test_alpha_2"

# ── Multi-worktree ───────────────────────────────────────────────────

header "multi-worktree — feat-beta migration"
cd "$WORKTREE_BASE/feat-beta"
cat > supabase/migrations/app/20260418000003_test_beta.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_beta (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "symlinked beta" "Symlinked 1 migration" "$OUTPUT"
assert_symlink_count "3 symlinks total" "3" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "beta table in DB" db_table_exists "test_beta"

# ── Stale symlink left by a sibling worktree ─────────────────────────
#
# Regression: feat-beta squashes/rebases away a migration it had already
# linked and applied. Its symlink in the supabase worktree now dangles while
# the history row survives — and `supabase migration up` then refuses to run
# at all (LegacyMigrationMissingLocalError) for EVERY worktree sharing the
# stack, including ones that changed nothing. `dev sb link` must clear the
# stale link AND its history row before applying, or it can never recover:
# the apply aborts first, so a cleanup placed after it never runs.

header "stale symlink from a sibling worktree does not wedge the stack"
rm "$WORKTREE_BASE/feat-beta/supabase/migrations/app/20260418000003_test_beta.sql"
assert "precondition: history still has the squashed version" db_version_exists "20260418000003"
assert "precondition: symlink now dangles" test ! -e \
  "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000003_test_beta.sql"

cd "$WORKTREE_BASE/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_not_contains "migration up not wedged" "LegacyMigrationMissingLocalError" "$OUTPUT"
assert_contains "stale link removed" "Removed 1 stale symlink" "$OUTPUT"
assert_contains "history repaired" "Repairing migration history" "$OUTPUT"
assert "squashed version dropped from history" db_version_not_exists "20260418000003"
assert "sibling's migrations survive" db_version_exists "20260418000001"
assert "alpha table still present" db_table_exists "test_alpha_2"
assert_symlink_count "2 symlinks remain" "2" "$WORKTREE_BASE/supabase/supabase/migrations"

# Restore beta so the ordered cases below see the state they expect.
cd "$WORKTREE_BASE/feat-beta"
cat > supabase/migrations/app/20260418000003_test_beta.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_beta (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
SQL
"$SCRIPTS_DIR/dev-supabase-link.sh" >/dev/null 2>&1 || true
assert_symlink_count "3 symlinks restored" "3" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "beta version re-applied" db_version_exists "20260418000003"

# ── Timestamp conflict ───────────────────────────────────────────────

header "timestamp conflict detection"
cd "$WORKTREE_BASE/feat-beta"
cat > supabase/migrations/app/20250101000001_test_outdated.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_outdated (id uuid PRIMARY KEY);
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "outdated timestamps" "outdated timestamps" "$OUTPUT"
assert_contains "fix instruction" "Fix: rebase feat-beta" "$OUTPUT"
assert_symlink_count "still 3 symlinks" "3" "$WORKTREE_BASE/supabase/supabase/migrations"
rm "$WORKTREE_BASE/feat-beta/supabase/migrations/app/20250101000001_test_outdated.sql"

# ── Unlink ───────────────────────────────────────────────────────────

header "dev sb unlink from feat-beta"
cd "$WORKTREE_BASE/feat-beta"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-unlink.sh" 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_symlink_count "2 symlinks remain" "2" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "beta version removed" db_version_not_exists "20260418000003"
assert "alpha versions intact" db_version_exists "20260418000001"

# Re-link for merge test
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_symlink_count "3 symlinks restored" "3" "$WORKTREE_BASE/supabase/supabase/migrations"

# ── Merge to main ────────────────────────────────────────────────────

header "merge to main — symlink replaced"
cd "$WORKTREE_BASE/main"
mkdir -p supabase/migrations/app
cp "$WORKTREE_BASE/feat-alpha/supabase/migrations/app/20260418000001_test_alpha.sql" \
   supabase/migrations/app/20260418000001_test_alpha.sql
git add supabase/migrations/app/20260418000001_test_alpha.sql
git commit -q -m "merge test-alpha migration"
git push -q origin main

cd "$WORKTREE_BASE/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert "merged is real file" test -f "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged is NOT symlink" test ! -L "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink "unmerged still symlinked" "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "2 symlinks remain" "2" "$WORKTREE_BASE/supabase/supabase/migrations"

# ── Teardown ─────────────────────────────────────────────────────────

header "dev wt down feat-beta"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-beta 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_file_not_exists "beta directory gone" "$WORKTREE_BASE/feat-beta"
assert_symlink_count "1 symlink remains" "1" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "beta version removed" db_version_not_exists "20260418000003"

header "dev wt down feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-alpha 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_file_not_exists "alpha directory gone" "$WORKTREE_BASE/feat-alpha"
assert "merged migration still real" test -f "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged not symlink" test ! -L "$WORKTREE_BASE/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink_count "no symlinks remain" "0" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "merged version in DB" db_version_exists "20260418000001"
assert "version 2 removed" db_version_not_exists "20260418000002"

# ── Post-cleanup sanity ──────────────────────────────────────────────

header "post-cleanup sanity"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "no new migrations" "No new migrations in main" "$OUTPUT"
assert_symlink_count "zero symlinks" "0" "$WORKTREE_BASE/supabase/supabase/migrations"
assert "init version in DB" db_version_exists "20260101000000"
assert "merged version in DB" db_version_exists "20260418000001"

print_results
