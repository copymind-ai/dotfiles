#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: Rollback lifecycle${RESET}\n"

# Entry state (left by 03-db-reset): main + supabase worktrees exist,
# Supabase running. This test creates its own feature worktree so it is
# independent of the worktrees earlier e2e tests tore down.
#
# MUST run before 05-db-flow-lifecycle: that test merges a pgflow
# migration to origin/main that is never applied (the fixture DB has no
# pgflow schema), which poisons every later `supabase migration up`.

db_table_missing() {
  local count
  count=$(db_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$1';")
  [ "$count" = "0" ]
}

# ── Setup ────────────────────────────────────────────────────────────

header "setup — create feat-rb worktree"
cd "$WORKTREE_BASE/main"
"$SCRIPTS_DIR/dev-worktree-up.sh" feat-rb >/dev/null 2>&1 || true
assert_file_exists "feat-rb created" "$WORKTREE_BASE/feat-rb"

# Three migrations: two covered by rollbacks (the second depends on the
# first, so rollback ORDER matters), one deliberately without a rollback.
cd "$WORKTREE_BASE/feat-rb"
mkdir -p supabase/rollbacks/app
cat > supabase/migrations/app/20260601000001_rb_probe.sql << 'SQL'
CREATE TABLE public.rb_probe (id int PRIMARY KEY);
SQL
cat > supabase/rollbacks/app/20260601000001_rb_probe.sql << 'SQL'
DROP TABLE public.rb_probe;
SQL
cat > supabase/migrations/app/20260601000002_rb_probe_note.sql << 'SQL'
ALTER TABLE public.rb_probe ADD COLUMN note text;
SQL
cat > supabase/rollbacks/app/20260601000002_rb_probe_note.sql << 'SQL'
ALTER TABLE public.rb_probe DROP COLUMN note;
SQL
cat > supabase/migrations/app/20260601000003_rb_orphan.sql << 'SQL'
CREATE TABLE public.rb_orphan (id int PRIMARY KEY);
SQL

# ── Link: lint + exclusion ───────────────────────────────────────────

header "link — lints missing rollback, ignores covered ones"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true
if ! echo "$OUTPUT" | grep -q "Symlinked 3 migration"; then
  printf "${DIM}link output (expected 3 symlinked):${RESET}\n%s\n" "$OUTPUT" >&2
fi
assert_contains "warns for uncovered migration" \
  "no rollback script for supabase/migrations/app/20260601000003_rb_orphan.sql" "$OUTPUT"
assert_contains "warning names the path to create" \
  "supabase/rollbacks/app/20260601000003_rb_orphan.sql" "$OUTPUT"
assert_not_contains "no warning for covered migration" \
  "no rollback script for supabase/migrations/app/20260601000001" "$OUTPUT"
assert_contains "all three symlinked" "Symlinked 3 migration" "$OUTPUT"
assert "rb_probe in DB" db_table_exists "rb_probe"
assert "rb_orphan in DB" db_table_exists "rb_orphan"

header "rollbacks are git-ignored, not committed"
assert_contains "info/exclude has entry" "supabase/rollbacks/" "$(cat "$WORKTREE_BASE/info/exclude")"
assert_eq "git status clean of rollbacks" "" "$(cd "$WORKTREE_BASE/feat-rb" && git status --porcelain | grep rollbacks || true)"

# ── Unlink: reverse-order revert + phantom warning ───────────────────

header "unlink — applies rollbacks newest-first, warns on orphan"
cd "$WORKTREE_BASE/feat-rb"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-unlink.sh" 2>&1) || true
if ! echo "$OUTPUT" | grep -q "Rolling back"; then
  printf "${DIM}unlink output (expected rollbacks):${RESET}\n%s\n" "$OUTPUT" >&2
fi
# `|| true` inside the pipeline: zero grep matches must yield an empty
# ORDER for the assert, not kill the test via pipefail.
ORDER=$({ echo "$OUTPUT" | grep 'Rolling back' || true; } | awk '{print $3}' | tr '\n' ' ')
assert_eq "reverse version order (column before table)" \
  "20260601000002 20260601000001 " "$ORDER"
assert "rb_probe reverted" db_table_missing "rb_probe"
assert "rb_orphan remains (no rollback)" db_table_exists "rb_orphan"
assert_contains "phantom schema warning" "left phantom schema" "$OUTPUT"
assert_contains "warning names orphan version" "20260601000003" "$OUTPUT"
assert "history row 1 removed" db_version_not_exists "20260601000001"
assert "history row 2 removed" db_version_not_exists "20260601000002"
assert "history row 3 removed" db_version_not_exists "20260601000003"

db_query "DROP TABLE public.rb_orphan;" >/dev/null

# ── wt down runs the same rollback path ──────────────────────────────

header "dev wt down — rollbacks applied during teardown"
cd "$WORKTREE_BASE/feat-rb"
"$SCRIPTS_DIR/dev-supabase-link.sh" >/dev/null 2>&1 || true
assert "precondition: rb_probe re-applied" db_table_exists "rb_probe"

cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-rb 2>&1) || true
assert_contains "rollbacks ran in teardown" "Rolling back 20260601000002" "$OUTPUT"
assert "rb_probe reverted by teardown" db_table_missing "rb_probe"
assert "rb_orphan remains again" db_table_exists "rb_orphan"
assert_contains "phantom warning in teardown" "left phantom schema" "$OUTPUT"
assert_file_not_exists "feat-rb directory gone" "$WORKTREE_BASE/feat-rb"

db_query "DROP TABLE public.rb_orphan;" >/dev/null

# ── unlink --reset: escape hatch for phantom schema ──────────────────

header "unlink --reset — full reset clears phantom schema"
cd "$WORKTREE_BASE/main"
cat > supabase/migrations/app/20260601000004_rb_orphan2.sql << 'SQL'
CREATE TABLE public.rb_orphan2 (id int PRIMARY KEY);
SQL
"$SCRIPTS_DIR/dev-supabase-link.sh" >/dev/null 2>&1 || true
assert "precondition: orphan2 in DB" db_table_exists "rb_orphan2"

OUTPUT=$("$SCRIPTS_DIR/dev-supabase-unlink.sh" --reset 2>&1) || true
assert_contains "reset ran" "Resetting local database" "$OUTPUT"
assert "orphan2 wiped by reset" db_table_missing "rb_orphan2"
assert "history row removed" db_version_not_exists "20260601000004"
assert "baseline migration reapplied" db_version_exists "20260101000000"
rm "$WORKTREE_BASE/main/supabase/migrations/app/20260601000004_rb_orphan2.sql"

# Leave the stack quiescent for 05-db-flow-lifecycle: the reset above
# spawned a fresh `supabase functions serve` seconds ago, and a process
# still initializing can recreate its edge-runtime container mid-way
# through 05's immediate `supabase stop` + `supabase start` dance.
pkill -f 'supabase functions serve' 2>/dev/null || true
sleep 2

print_results
