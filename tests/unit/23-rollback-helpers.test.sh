#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: rollback helpers${RESET}\n"

setup_tmpdir
STUB_BIN="$TEST_TMPDIR/bin"
STUB_LOG="$TEST_TMPDIR/psql.log"
mkdir -p "$STUB_BIN"

# `psql` stub: logs each -f <file> in call order; exits 1 when the file's
# basename contains "fail" (simulates a broken rollback script).
cat > "$STUB_BIN/psql" <<STUB
#!/usr/bin/env bash
set -u
file=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-f" ] && file="\$a"
  prev="\$a"
done
if [ -n "\$file" ]; then
  base=\$(basename "\$file")
  echo "APPLIED: \$base" >> "$STUB_LOG"
  case "\$base" in *fail*) exit 1 ;; esac
fi
exit 0
STUB
chmod +x "$STUB_BIN/psql"

# The helpers module guards on `supabase` being present at source-time.
cat > "$STUB_BIN/supabase" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/supabase"

PATH="$STUB_BIN:$PATH"
export PATH

source "$SCRIPTS_DIR/dev-supabase.helpers.sh"

# ── rollback_path_for ────────────────────────────────────────────────

header "rollback_path_for maps migrations/ to rollbacks/"
WT="$TEST_TMPDIR/wt"
mkdir -p "$WT/supabase/rollbacks/app"
touch "$WT/supabase/rollbacks/app/20260601000001_probe.sql"
touch "$WT/supabase/rollbacks/20260601000002_flat.sql"

RESULT=$(rollback_path_for "$WT" "supabase/migrations/app/20260601000001_probe.sql")
assert_eq "subdir migration maps to rollbacks/app/" \
  "$WT/supabase/rollbacks/app/20260601000001_probe.sql" "$RESULT"

RESULT=$(rollback_path_for "$WT" "supabase/migrations/20260601000002_flat.sql")
assert_eq "flat-root migration maps to rollbacks/" \
  "$WT/supabase/rollbacks/20260601000002_flat.sql" "$RESULT"

EXIT_CODE=0
rollback_path_for "$WT" "supabase/migrations/app/20260601000003_missing.sql" >/dev/null || EXIT_CODE=$?
assert_exit_code "missing rollback returns 1" "1" "$EXIT_CODE"

# ── apply_rollbacks — reverse order ──────────────────────────────────

header "apply_rollbacks runs newest version first"
SB_WT="$TEST_TMPDIR/sb"
mkdir -p "$SB_WT/supabase"
cat > "$SB_WT/supabase/config.toml" <<TOML
project_id = "unit-test"
[db]
port = 54722
TOML

RB_DIR="$TEST_TMPDIR/rb"
mkdir -p "$RB_DIR"
echo "DROP TABLE a;" > "$RB_DIR/20260601000001_first.sql"
echo "DROP TABLE b;" > "$RB_DIR/20260601000002_second.sql"
echo "DROP TABLE c;" > "$RB_DIR/20260601000003_third.sql"

: > "$STUB_LOG"
apply_rollbacks "$SB_WT" \
  "20260601000001"$'\t'"$RB_DIR/20260601000001_first.sql" \
  "20260601000003"$'\t'"$RB_DIR/20260601000003_third.sql" \
  "20260601000002"$'\t'"$RB_DIR/20260601000002_second.sql"

ORDER=$(sed 's/APPLIED: //' "$STUB_LOG" | tr '\n' ' ')
assert_eq "applied newest-first regardless of arg order" \
  "20260601000003_third.sql 20260601000002_second.sql 20260601000001_first.sql " "$ORDER"
assert_eq "all counted as applied" "3" "$APPLIED_ROLLBACK_COUNT"
assert_eq "no failures collected" "" "$FAILED_ROLLBACK_VERSIONS"

# ── apply_rollbacks — failure does not abort the loop ────────────────

header "apply_rollbacks collects failures and continues"
echo "boom" > "$RB_DIR/20260601000005_fail_mid.sql"
: > "$STUB_LOG"
apply_rollbacks "$SB_WT" \
  "20260601000005"$'\t'"$RB_DIR/20260601000005_fail_mid.sql" \
  "20260601000001"$'\t'"$RB_DIR/20260601000001_first.sql"

assert_eq "failed version collected" "20260601000005" "$FAILED_ROLLBACK_VERSIONS"
assert_eq "later rollback still applied" "1" "$APPLIED_ROLLBACK_COUNT"
assert_contains "older rollback ran after the failure" "20260601000001_first.sql" "$(cat "$STUB_LOG")"

# ── ensure_rollbacks_excluded ────────────────────────────────────────

header "ensure_rollbacks_excluded is idempotent"
REPO="$TEST_TMPDIR/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q)
cd "$REPO"

OUTPUT=$(ensure_rollbacks_excluded)
assert_contains "announces on first run" "Ignoring supabase/rollbacks/" "$OUTPUT"
assert_contains "entry written to info/exclude" "supabase/rollbacks/" "$(cat "$REPO/.git/info/exclude")"

OUTPUT=$(ensure_rollbacks_excluded)
assert_eq "silent on second run" "" "$OUTPUT"
COUNT=$(grep -cx 'supabase/rollbacks/' "$REPO/.git/info/exclude")
assert_eq "entry not duplicated" "1" "$COUNT"

print_results
