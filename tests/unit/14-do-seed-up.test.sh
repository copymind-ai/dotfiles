#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: do_seed_up${RESET}\n"

setup_tmpdir
STUB_BIN="$TEST_TMPDIR/bin"
STUB_LOG="$TEST_TMPDIR/psql.log"
STUB_STATE="$TEST_TMPDIR/applied_seeds.state"
mkdir -p "$STUB_BIN"

# `psql` stub:
#  - Persists "already applied" state in STUB_STATE (one filename per line)
#  - For SELECT 1 FROM applied_seeds WHERE name = 'X' — returns 1 if X is in state, else empty
#  - For INSERT INTO applied_seeds — appends filename to state
#  - For -f <path> — records the seed file that was "applied" (would crash if called on users.sql)
#  - All other SQL (CREATE SCHEMA / CREATE TABLE) — no-op
cat > "$STUB_BIN/psql" <<STUB
#!/usr/bin/env bash
set -u
STATE_FILE="$STUB_STATE"
touch "\$STATE_FILE"
echo "ARGS: \$*" >> "$STUB_LOG"

file=""
sql=""
prev=""
for a in "\$@"; do
  case "\$prev" in
    -f) file="\$a" ;;
    -c) sql="\$a" ;;
  esac
  prev="\$a"
done

if [ -n "\$file" ]; then
  base=\$(basename "\$file")
  if [ "\$base" = "users.sql" ]; then
    echo "FATAL: users.sql must be skipped by do_seed_up" >&2
    exit 1
  fi
  echo "APPLIED: \$base" >> "$STUB_LOG"
  exit 0
fi

if echo "\$sql" | grep -q "SELECT 1 FROM supabase_seeds.applied_seeds WHERE name"; then
  name=\$(echo "\$sql" | sed -n "s/.*name = '\\(.*\\)'.*/\\1/p")
  if grep -Fxq "\$name" "\$STATE_FILE"; then
    echo "1"
  fi
  exit 0
fi

if echo "\$sql" | grep -q "INSERT INTO supabase_seeds.applied_seeds"; then
  name=\$(echo "\$sql" | sed -n "s/.*VALUES ('\\(.*\\)').*/\\1/p")
  echo "\$name" >> "\$STATE_FILE"
  exit 0
fi

exit 0
STUB
chmod +x "$STUB_BIN/psql"

# do_seed_up itself doesn't invoke `supabase`, but the helpers module guards
# on `supabase` being present at source-time. Provide a minimal stub.
cat > "$STUB_BIN/supabase" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/supabase"

PATH="$STUB_BIN:$PATH"
export PATH

source "$SCRIPTS_DIR/dev-supabase.helpers.sh"

_make_fixture_wt() {
  local wt="$1"
  mkdir -p "$wt/supabase/seeds"
  cat > "$wt/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54722
TOML
  echo "INSERT INTO x VALUES (1);" > "$wt/supabase/seeds/001_a.sql"
  echo "INSERT INTO x VALUES (2);" > "$wt/supabase/seeds/002_b.sql"
  echo "SELECT 1/0;" > "$wt/supabase/seeds/users.sql"
}

# ── fresh registry — applies new seeds, skips users.sql ──────────────
header "applies new seeds, skips users.sql"
WT="$TEST_TMPDIR/wt1"
_make_fixture_wt "$WT"
: > "$STUB_LOG"
rm -f "$STUB_STATE"

OUTPUT=$(do_seed_up "$WT")

assert_contains "applied 001_a" "APPLIED: 001_a.sql" "$(cat "$STUB_LOG")"
assert_contains "applied 002_b" "APPLIED: 002_b.sql" "$(cat "$STUB_LOG")"
assert_not_contains "users.sql NOT applied" "APPLIED: users.sql" "$(cat "$STUB_LOG")"
assert_contains "prints 2 applied" "2 applied" "$OUTPUT"

# ── re-run — idempotent, zero applied ────────────────────────────────
header "re-run is idempotent"
: > "$STUB_LOG"
# state persists from prior run — 001/002 are already in $STUB_STATE
OUTPUT=$(do_seed_up "$WT")

assert_not_contains "001_a NOT re-applied" "APPLIED: 001_a.sql" "$(cat "$STUB_LOG")"
assert_not_contains "002_b NOT re-applied" "APPLIED: 002_b.sql" "$(cat "$STUB_LOG")"
assert_contains "prints 0 applied" "0 applied" "$OUTPUT"
assert_contains "prints 2 already up to date" "2 already up to date" "$OUTPUT"

# ── renamed seed IS applied ──────────────────────────────────────────
header "renamed seed treated as new"
mv "$WT/supabase/seeds/001_a.sql" "$WT/supabase/seeds/003_a_renamed.sql"
: > "$STUB_LOG"
OUTPUT=$(do_seed_up "$WT")

assert_contains "renamed file applied" "APPLIED: 003_a_renamed.sql" "$(cat "$STUB_LOG")"
assert_contains "prints 1 applied" "1 applied" "$OUTPUT"

# ── missing seeds directory ──────────────────────────────────────────
header "no-op when seeds directory missing"
WT2="$TEST_TMPDIR/wt2"
mkdir -p "$WT2/supabase"
cat > "$WT2/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54799
TOML

OUTPUT=$(do_seed_up "$WT2")
assert_contains "prints no-op" "No seeds directory" "$OUTPUT"

print_results
