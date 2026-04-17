#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}01 — Unit logic (pure functions)${RESET}\n"

# ── Name sanitization ────────────────────────────────────────────────

header "name sanitization"

sanitize() { echo "$1" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-'; }

assert_eq "slashes become dashes" "feat-new-chat" "$(sanitize "feat/new-chat")"
assert_eq "nested slashes" "feat-team-new-chat" "$(sanitize "feat/team/new-chat")"
assert_eq "plain name unchanged" "my-branch" "$(sanitize "my-branch")"
assert_eq "special chars stripped" "featbranch" "$(sanitize "feat@branch!")"
assert_eq "dots preserved" "v1.2.3" "$(sanitize "v1.2.3")"
assert_eq "underscores preserved" "feat_thing" "$(sanitize "feat_thing")"

# ── Port allocation logic ────────────────────────────────────────────

header "port allocation"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"

MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13000" "13001" "$NEW_PORT"

printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13001" "13002" "$NEW_PORT"

BASE_PORT=13000
printf "feat-overflow\t13099\t2026-01-03\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert "port overflow detected" test "$NEW_PORT" -ge $((BASE_PORT + 100))

# ── Port registry removal ────────────────────────────────────────────

header "port registry removal"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"
printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
printf "feat-b\t13002\t2026-01-03\n" >> "$REGISTRY"

SAFE_NAME="feat-a"
grep -v "^${SAFE_NAME}	" "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

assert_not_contains "feat-a removed" "feat-a" "$(cat "$REGISTRY")"
assert_contains "main still present" "main" "$(cat "$REGISTRY")"
assert_contains "feat-b still present" "feat-b" "$(cat "$REGISTRY")"

# ── upsert_env ────────────────────────────────────────────────────────

_source_fn() {
  eval "$(sed -n "/^${1}()/,/^}/p" "$SCRIPTS_DIR/dev-worktree-env.sh")"
}
_source_fn upsert_env
_source_fn classify_supabase_var
_source_fn discover_supabase_vars

header "upsert_env — insert and update"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
echo "EXISTING_KEY=old_value" > "$ENV"

upsert_env "$ENV" "NEW_KEY" "new_value"
assert_contains "new key appended" "NEW_KEY=new_value" "$(cat "$ENV")"
assert_contains "existing key untouched" "EXISTING_KEY=old_value" "$(cat "$ENV")"

upsert_env "$ENV" "EXISTING_KEY" "updated_value"
assert_contains "key updated" "EXISTING_KEY=updated_value" "$(cat "$ENV")"
assert_not_contains "old value gone" "old_value" "$(cat "$ENV")"

header "upsert_env — empty file, no double newlines"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
touch "$ENV"
upsert_env "$ENV" "FIRST_KEY" "first_value"
assert_contains "key written to empty file" "FIRST_KEY=first_value" "$(cat "$ENV")"

printf "KEY1=val1" > "$ENV"  # no trailing newline
upsert_env "$ENV" "KEY2" "val2"
upsert_env "$ENV" "KEY3" "val3"
BLANK_LINES=$(grep -c '^$' "$ENV" || true)
assert_eq "no blank lines" "0" "$BLANK_LINES"

# ── classify_supabase_var ─────────────────────────────────────────────

header "classify_supabase_var"

assert_eq "SUPABASE_URL → API_URL" "API_URL" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_URL")"
assert_eq "ANON_KEY" "ANON_KEY" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")"
assert_eq "SERVICE_ROLE_KEY" "SERVICE_ROLE_KEY" "$(classify_supabase_var "SUPABASE_SERVICE_ROLE_KEY")"
assert_eq "DB_URL" "DB_URL" "$(classify_supabase_var "DATABASE_URL")"
assert_eq "JWT_SECRET" "JWT_SECRET" "$(classify_supabase_var "JWT_SECRET")"
assert_eq "unmapped → empty" "" "$(classify_supabase_var "SOME_OTHER_VAR")"

# ── discover_supabase_vars ────────────────────────────────────────────

header "discover_supabase_vars"
setup_tmpdir

WORKTREE="$TEST_TMPDIR/worktree"
mkdir -p "$WORKTREE/src/lib"
ENV="$WORKTREE/.env.local"

cat > "$WORKTREE/src/lib/config.ts" << 'TS'
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const other = process.env.NODE_ENV;
TS
cat > "$ENV" << 'ENV'
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
DATABASE_URL=postgresql://localhost/db
UNRELATED_VAR=foo
ENV

VARS="$(discover_supabase_vars "$WORKTREE" "$ENV")"
assert_contains "finds SUPABASE_URL" "NEXT_PUBLIC_SUPABASE_URL" "$VARS"
assert_contains "finds ANON_KEY" "NEXT_PUBLIC_SUPABASE_ANON_KEY" "$VARS"
assert_contains "finds DATABASE_URL" "DATABASE_URL" "$VARS"
assert_not_contains "excludes NODE_ENV" "NODE_ENV" "$VARS"
assert_not_contains "excludes UNRELATED_VAR" "UNRELATED_VAR" "$VARS"

# ── migrate functions ─────────────────────────────────────────────────

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn find_new_migrations)"
eval "$(_extract_fn get_latest_origin_timestamp)"
eval "$(_extract_fn symlink_migrations)"
eval "$(_extract_fn remove_wt_symlinks)"
eval "$(_extract_fn clean_stale_symlinks)"

header "find_new_migrations"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE a;" > "$WT/supabase/migrations/app/20260418000001_a.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_contains "detects new migration" "20260418000001_a.sql" "$RESULT"

echo "CREATE TABLE a;" > "$SB/supabase/migrations/app/20260418000001_a.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "skips real file from origin" "" "$RESULT"

header "find_new_migrations — symlink handling"
setup_tmpdir

WT="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT/supabase/migrations/app/20260418000002_b.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_b.sql" "$SB/supabase/migrations/app/20260418000002_b.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "skips correctly symlinked" "" "$RESULT"

header "get_latest_origin_timestamp"
setup_tmpdir

SB="$TEST_TMPDIR/supabase"
mkdir -p "$SB/supabase/migrations/app"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"
echo "sql" > "$SB/supabase/migrations/app/20260418000001_feature.sql"
ln -s "/fake/path.sql" "$SB/supabase/migrations/app/20260501000000_symlink.sql"

RESULT="$(get_latest_origin_timestamp "$SB")"
assert_eq "returns latest real timestamp" "20260418000001" "$RESULT"

header "symlink_migrations"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"
echo "sql" > "$WT/supabase/migrations/app/20260418000001_x.sql"

OUTPUT=$(symlink_migrations "$WT" "supabase/migrations/app/20260418000001_x.sql" "$SB")
assert_symlink "symlink created" "$SB/supabase/migrations/app/20260418000001_x.sql"
assert_contains "reports count" "Symlinked 1" "$OUTPUT"

header "remove_wt_symlinks"
setup_tmpdir

WT_A="$TEST_TMPDIR/feat-a"
WT_B="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT_A/supabase/migrations/app" "$WT_B/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT_A/supabase/migrations/app/20260418000001_a.sql"
echo "sql" > "$WT_B/supabase/migrations/app/20260418000003_b.sql"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"
ln -s "$WT_A/supabase/migrations/app/20260418000001_a.sql" "$SB/supabase/migrations/app/20260418000001_a.sql"
ln -s "$WT_B/supabase/migrations/app/20260418000003_b.sql" "$SB/supabase/migrations/app/20260418000003_b.sql"

OUTPUT=$(remove_wt_symlinks "$WT_A" "$SB")
assert_contains "reports 1 removed" "Removed 1" "$OUTPUT"
assert_file_not_exists "a.sql removed" "$SB/supabase/migrations/app/20260418000001_a.sql"
assert_symlink "b.sql still intact" "$SB/supabase/migrations/app/20260418000003_b.sql"

header "clean_stale_symlinks"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000001_exists.sql" "$SB/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_deleted.sql" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")
assert_contains "reports 1 stale removed" "Removed 1 stale" "$OUTPUT"
assert_symlink "valid symlink untouched" "$SB/supabase/migrations/app/20260418000001_exists.sql"
assert_file_not_exists "stale symlink removed" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

print_results
