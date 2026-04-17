#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: Migration lifecycle${RESET}\n"

# At this point: feat-alpha + feat-beta exist, Supabase running, no migrations linked

# ── Link ─────────────────────────────────────────────────────────────

header "no new migrations initially"
cd "$TEST_DIR/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "reports no new" "No new migrations in feat-alpha" "$OUTPUT"
assert_symlink_count "no symlinks in hub" "0" "$TEST_DIR/supabase/supabase/migrations"

header "new migration — symlink + apply"
cd "$TEST_DIR/feat-alpha"
cat > supabase/migrations/app/20260418000001_test_alpha.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now()
);
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "found new" "Found new migrations in feat-alpha" "$OUTPUT"
assert_contains "symlinked 1" "Symlinked 1 migration" "$OUTPUT"
assert_symlink "symlink created" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
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
assert_symlink_count "2 symlinks total" "2" "$TEST_DIR/supabase/supabase/migrations"
assert "second table in DB" db_table_exists "test_alpha_2"

# ── Multi-worktree ───────────────────────────────────────────────────

header "multi-worktree — feat-beta migration"
cd "$TEST_DIR/feat-beta"
cat > supabase/migrations/app/20260418000003_test_beta.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_beta (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "symlinked beta" "Symlinked 1 migration" "$OUTPUT"
assert_symlink_count "3 symlinks total" "3" "$TEST_DIR/supabase/supabase/migrations"
assert "beta table in DB" db_table_exists "test_beta"

# ── Timestamp conflict ───────────────────────────────────────────────

header "timestamp conflict detection"
cd "$TEST_DIR/feat-beta"
cat > supabase/migrations/app/20250101000001_test_outdated.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_outdated (id uuid PRIMARY KEY);
SQL
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "outdated timestamps" "outdated timestamps" "$OUTPUT"
assert_contains "fix instruction" "Fix: rebase feat-beta" "$OUTPUT"
assert_symlink_count "still 3 symlinks" "3" "$TEST_DIR/supabase/supabase/migrations"
rm "$TEST_DIR/feat-beta/supabase/migrations/app/20250101000001_test_outdated.sql"

# ── Unlink ───────────────────────────────────────────────────────────

header "dev sb unlink from feat-beta"
cd "$TEST_DIR/feat-beta"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-unlink.sh" 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_symlink_count "2 symlinks remain" "2" "$TEST_DIR/supabase/supabase/migrations"
assert "beta version removed" db_version_not_exists "20260418000003"
assert "alpha versions intact" db_version_exists "20260418000001"

# Re-link for merge test
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_symlink_count "3 symlinks restored" "3" "$TEST_DIR/supabase/supabase/migrations"

# ── Merge to main ────────────────────────────────────────────────────

header "merge to main — symlink replaced"
cd "$TEST_DIR/main"
mkdir -p supabase/migrations/app
cp "$TEST_DIR/feat-alpha/supabase/migrations/app/20260418000001_test_alpha.sql" \
   supabase/migrations/app/20260418000001_test_alpha.sql
git add supabase/migrations/app/20260418000001_test_alpha.sql
git commit -q -m "merge test-alpha migration"
git push -q origin main

cd "$TEST_DIR/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert "merged is real file" test -f "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged is NOT symlink" test ! -L "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink "unmerged still symlinked" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "2 symlinks remain" "2" "$TEST_DIR/supabase/supabase/migrations"

# ── Teardown ─────────────────────────────────────────────────────────

header "dev wt down feat-beta"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-beta 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_file_not_exists "beta directory gone" "$TEST_DIR/feat-beta"
assert_symlink_count "1 symlink remains" "1" "$TEST_DIR/supabase/supabase/migrations"
assert "beta version removed" db_version_not_exists "20260418000003"

header "dev wt down feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-alpha 2>&1) || true
assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_file_not_exists "alpha directory gone" "$TEST_DIR/feat-alpha"
assert "merged migration still real" test -f "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged not symlink" test ! -L "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink_count "no symlinks remain" "0" "$TEST_DIR/supabase/supabase/migrations"
assert "merged version in DB" db_version_exists "20260418000001"
assert "version 2 removed" db_version_not_exists "20260418000002"

# ── Post-cleanup sanity ──────────────────────────────────────────────

header "post-cleanup sanity"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
assert_contains "no new migrations" "No new migrations in main" "$OUTPUT"
assert_symlink_count "zero symlinks" "0" "$TEST_DIR/supabase/supabase/migrations"
assert "init version in DB" db_version_exists "20260101000000"
assert "merged version in DB" db_version_exists "20260418000001"

print_results
