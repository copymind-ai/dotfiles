#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: do_migrate_up${RESET}\n"

# Shadow `supabase` on PATH so do_migrate_up hits a recording stub.
setup_tmpdir
STUB_BIN="$TEST_TMPDIR/bin"
STUB_LOG="$TEST_TMPDIR/supabase.log"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/supabase" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$STUB_LOG"
exit \${FAKE_EXIT:-0}
STUB
chmod +x "$STUB_BIN/supabase"
PATH="$STUB_BIN:$PATH"
export PATH

# Source the helper module. It unconditionally checks for a `supabase` binary
# on PATH — our stub satisfies that.
source "$SCRIPTS_DIR/dev-supabase.helpers.sh"

_make_fixture_wt() {
  local wt="$1"
  mkdir -p "$wt/supabase/migrations/app" "$wt/supabase/migrations/jobs"
  cat > "$wt/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54722
TOML
  echo "-- app" > "$wt/supabase/migrations/app/20260101000000_init.sql"
  echo "-- jobs" > "$wt/supabase/migrations/jobs/20260101000001_job.sql"
}

# ── happy path ───────────────────────────────────────────────────────
header "flattens, calls supabase migration up, restores"
WT="$TEST_TMPDIR/wt1"
_make_fixture_wt "$WT"
: > "$STUB_LOG"

do_migrate_up "$WT" >/dev/null

assert_file_exists "app subdir restored" "$WT/supabase/migrations/app"
assert_file_exists "jobs subdir restored" "$WT/supabase/migrations/jobs"
assert_file_not_exists "split dir removed" "$WT/supabase/migrations_split"
assert_file_not_exists "flat temp dir removed" "$WT/supabase/migrations_flat"
assert_contains "supabase invoked with migration up" "migration up" "$(cat "$STUB_LOG")"
assert_contains "uses parsed [db] port" "127.0.0.1:54722" "$(cat "$STUB_LOG")"
assert_contains "uses supabase_admin user" "supabase_admin" "$(cat "$STUB_LOG")"

# ── failure restores layout ──────────────────────────────────────────
header "restores subdir layout on failure"
WT="$TEST_TMPDIR/wt2"
_make_fixture_wt "$WT"
: > "$STUB_LOG"

FAKE_EXIT=1 do_migrate_up "$WT" >/dev/null 2>&1 || true

assert_file_exists "app subdir restored after failure" "$WT/supabase/migrations/app"
assert_file_exists "jobs subdir restored after failure" "$WT/supabase/migrations/jobs"
assert_file_not_exists "split dir removed after failure" "$WT/supabase/migrations_split"

# ── flat-already layout (no subdirs) ─────────────────────────────────
header "no-op flatten when migrations are flat"
WT="$TEST_TMPDIR/wt3"
mkdir -p "$WT/supabase/migrations"
cat > "$WT/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54723
TOML
echo "-- flat" > "$WT/supabase/migrations/20260101000000_flat.sql"
: > "$STUB_LOG"

do_migrate_up "$WT" >/dev/null

assert_file_exists "flat migration still present" "$WT/supabase/migrations/20260101000000_flat.sql"
assert_file_not_exists "no split dir created" "$WT/supabase/migrations_split"
assert_contains "supabase still invoked" "migration up" "$(cat "$STUB_LOG")"

# ── missing migrations dir ───────────────────────────────────────────
header "returns cleanly when no migrations directory"
WT="$TEST_TMPDIR/wt4"
mkdir -p "$WT/supabase"
cat > "$WT/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54724
TOML
: > "$STUB_LOG"

OUTPUT=$(do_migrate_up "$WT" 2>&1)
assert_contains "prints no-op message" "No migrations directory" "$OUTPUT"
assert_eq "supabase not invoked" "" "$(cat "$STUB_LOG")"

print_results
