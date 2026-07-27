#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: clean_stale_symlinks${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase.helpers.sh"
}
eval "$(_extract_fn list_migration_dirs)"
eval "$(_extract_fn get_project_id)"
eval "$(_extract_fn migration_version_of)"
eval "$(_extract_fn repair_migration_history)"
eval "$(_extract_fn clean_stale_symlinks)"
eval "$(_extract_fn clean_all_stale_symlinks)"

# `repair_migration_history` shells out to `docker exec … psql`. Stub docker
# so the SQL it would run is recorded rather than executed — these cases are
# about WHICH versions get repaired, not about Postgres.
setup_tmpdir
STUB_BIN="$TEST_TMPDIR/bin"
DOCKER_LOG="$TEST_TMPDIR/docker.log"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCKER_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/docker"
PATH="$STUB_BIN:$PATH"
export PATH

# A feature worktree + supabase worktree pair. Every migration named gets a
# symlink in the supabase worktree; only those marked `live` get a real target
# file, so the rest stand in for symlinks orphaned by a rebase or squash in
# the feature worktree.
_fixture() {
  setup_tmpdir
  : > "$DOCKER_LOG"
  WT="$TEST_TMPDIR/feat-a"
  SB="$TEST_TMPDIR/supabase"
  mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"
  cat > "$SB/supabase/config.toml" <<'TOML'
project_id = "test-unit"
TOML
}

_link() { # <filename> [live]
  local name="$1" live="${2:-}"
  [ -n "$live" ] && echo "sql" > "$WT/supabase/migrations/app/$name"
  ln -s "$WT/supabase/migrations/app/$name" "$SB/supabase/migrations/app/$name"
}

header "removes broken symlinks"
_fixture
_link 20260418000001_exists.sql live
_link 20260418000002_deleted.sql

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")
assert_contains "reports 1 stale removed" "Removed 1 stale" "$OUTPUT"
assert_symlink "valid symlink untouched" "$SB/supabase/migrations/app/20260418000001_exists.sql"
assert_file_not_exists "stale symlink removed" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

# The regression this guards: dropping a migration FILE without dropping its
# history row leaves the Supabase CLI unable to run at all
# (LegacyMigrationMissingLocalError) for every worktree sharing the stack.
header "repairs migration history for the versions it removed"
_fixture
_link 20260418000001_exists.sql live
_link 20260418000002_deleted.sql
_link 20260418000003_squashed.sql

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")
DOCKER_CALLS="$(cat "$DOCKER_LOG")"
assert_contains "announces the repair" "Repairing migration history" "$OUTPUT"
assert_contains "targets the history table" \
  "DELETE FROM supabase_migrations.schema_migrations" "$DOCKER_CALLS"
assert_contains "repairs the first stale version" "'20260418000002'" "$DOCKER_CALLS"
assert_contains "repairs the second stale version" "'20260418000003'" "$DOCKER_CALLS"
assert_not_contains "leaves the live version applied" "'20260418000001'" "$DOCKER_CALLS"
assert_contains "uses the project's db container" "supabase_db_test-unit" "$DOCKER_CALLS"

header "does not touch history when nothing is stale"
_fixture
_link 20260418000001_exists.sql live

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")
assert_not_contains "no repair announced" "Repairing migration history" "$OUTPUT"
assert_eq "docker never invoked" "" "$(cat "$DOCKER_LOG")"

# `dev sb sync` cleans stale symlinks across ALL worktrees, so it needs the
# same repair — a stale link owned by another worktree breaks the CLI just as
# thoroughly.
header "clean_all_stale_symlinks repairs history too"
_fixture
_link 20260418000001_exists.sql live
_link 20260418000004_orphan.sql

OUTPUT=$(clean_all_stale_symlinks "$SB")
DOCKER_CALLS="$(cat "$DOCKER_LOG")"
assert_contains "reports 1 stale removed" "Removed 1 stale" "$OUTPUT"
assert_contains "repairs the orphaned version" "'20260418000004'" "$DOCKER_CALLS"
assert_not_contains "leaves the live version applied" "'20260418000001'" "$DOCKER_CALLS"

header "migration_version_of parses the timestamp prefix"
assert_eq "strips name and extension" "20260726091727" \
  "$(migration_version_of /a/b/20260726091727_updated_at_triggers.sql)"
assert_eq "handles underscores in the name" "20260418000002" \
  "$(migration_version_of 20260418000002_chat_messages_updated_at.sql)"

print_results
