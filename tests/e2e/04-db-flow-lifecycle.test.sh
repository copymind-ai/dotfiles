#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: dev sb flow lifecycle${RESET}\n"

# Entry state (left by 03-db-reset):
#   - Supabase running with edge_runtime enabled
#   - feat-gamma worktree exists
#   - shared supabase worktree has supabase/flows/noop.ts (git-tracked from fixture)
#
# This file tests the released-flow guard — the pre-pass validation that
# prevents rewriting a flow's migration once it's on origin/main.
#
# The scenario deliberately boots the stack from a feature worktree before
# invoking `dev sb flow`. That's a hostile starting state, not a behaviour
# we promise to heal: we only assert the guard still fires correctly in
# spite of it. Anchor drift shouldn't happen in practice — every `dev sb`
# lifecycle command `cd`s into the shared supabase worktree before calling
# `supabase start`, so the edge runtime is always anchored there unless a
# user runs raw `supabase ...` from a feature worktree.
#
# End-to-end **worker boot** (Deno resolving jsr.io/npm from inside the
# edge-runtime container) is NOT tested here: Docker Desktop on macOS
# can't reliably resolve those registries without a pre-warmed cache.
# That path is covered by pgflow's own test suite.
#
# We DO exercise real `npx pgflow compile` on the success path below —
# compile runs on the host, not inside Docker, so the macOS Desktop DNS
# quirk doesn't apply. The assertions only check artifacts on disk, not
# whether the worker successfully boots and polls.

SHARED_WT="$WORKTREE_BASE/supabase"
PROJECT_ID="test-int"
EDGE_CONTAINER="supabase_edge_runtime_${PROJECT_ID}"
FEAT_WT="$WORKTREE_BASE/feat-gamma"

# ── Pre-flight: confirm edge runtime container actually exists ───────

header "pre-flight — edge runtime container running"
if ! docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
  echo "  ${RED}✗${RESET} edge runtime container '$EDGE_CONTAINER' is not running."
  echo "    This test requires the fixture's config.toml to enable [edge_runtime]."
  # Skip gracefully so the rest of the suite still reports.
  print_results
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# Released-flow guard — pre-pass validation that prevents rewriting a
# flow migration once it's on origin/main.
# ══════════════════════════════════════════════════════════════════════

SLUG="mirror"
MIG_TS="20260501000000"
MIG_BASENAME="${MIG_TS}_create_${SLUG}_flow.sql"

# ── Hostile starting state: stack booted from a feature worktree ─────
# The guard must fire correctly even when the stack happens to be
# anchored elsewhere. We don't assert anything about the anchor after
# — that's not a contract, just an incidental side effect of the
# restart that runs for bind-mount reasons.

header "boot stack from feat-gamma (hostile starting state)"
(cd "$SHARED_WT" && supabase stop --no-backup >/dev/null 2>&1) || true
cd "$FEAT_WT"
supabase start >/dev/null 2>&1

# ── Setup: add flow source + a hand-crafted migration to feat-gamma ──
# We bypass real pgflow compilation by pre-placing the migration file the
# compile step would have produced. The released-flow guard checks for a
# matching migration basename on origin/main, independent of the compile.

header "setup — add mirror flow + hand-crafted migration in feat-gamma"
cat > "$FEAT_WT/supabase/flows/mirror.ts" <<'TS'
import { Flow } from "@pgflow/dsl";

export const Mirror = new Flow<{ value: string }>({
  slug: "mirror",
}).step({ slug: "reflect" }, (input) => ({ value: input.run.value }));
TS
cat > "$FEAT_WT/supabase/flows/index.ts" <<'TS'
export { Noop } from "./noop.ts";
export { Mirror } from "./mirror.ts";
TS

mkdir -p "$FEAT_WT/supabase/migrations/jobs"
cat > "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}" <<SQL
SELECT pgflow.create_flow('${SLUG}', max_attempts => 3, base_delay => 1);
SELECT pgflow.add_step('${SLUG}', 'reflect');
SQL

# Source must be newer than the migration so the script's mtime-skip branch
# doesn't short-circuit past the released-flow guard we're here to test.
backdate "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}"

# ── Merge the migration to origin/main — flow becomes "released" ─────

header "merge mirror migration to origin/main"
cd "$WORKTREE_BASE/main"
mkdir -p supabase/migrations/jobs supabase/flows
cp "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}" supabase/migrations/jobs/
cp "$FEAT_WT/supabase/flows/mirror.ts" supabase/flows/mirror.ts
cat > supabase/flows/index.ts <<'TS'
export { Noop } from "./noop.ts";
export { Mirror } from "./mirror.ts";
TS
git add supabase/migrations/jobs/"${MIG_BASENAME}" supabase/flows/mirror.ts supabase/flows/index.ts
git commit -q -m "release mirror flow"
git push -q origin main

# ── dev sb flow mirror from feat-gamma — guard fires ────────────────

header "dev sb flow mirror from feat-gamma — released-flow guard fires"
cd "$FEAT_WT"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow "$SLUG" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" != "1" ]; then
  printf "${DIM}flow output (expected non-zero):${RESET}\n%s\n" "$OUTPUT" >&2
fi
assert_exit_code "exits 1 (released-flow guard)" "1" "$EXIT_CODE"
assert_contains "flags released-flow state" "released on origin/main" "$OUTPUT"
assert_contains "points at versioning guide" "version-flows" "$OUTPUT"

# Shared wt flows must be restored after the guard-triggered abort
assert_file_exists "shared wt still has noop.ts" "$SHARED_WT/supabase/flows/noop.ts"
assert_file_not_exists "shared wt has no mirror.ts (trap restored)" "$SHARED_WT/supabase/flows/mirror.ts"

# ══════════════════════════════════════════════════════════════════════
# Success path — a fresh unreleased flow compiles, scaffolds a worker,
# and leaves the synced flow TS + worker dir + job-key.ts in the shared
# worktree so `supabase functions serve` can discover + boot them.
#
# This catches three past regressions in one:
#   1. Trap-on-success wiping flows/* + job-key.ts from shared wt
#   2. scaffold_pgflow_worker landing only in the invoking worktree,
#      leaving `supabase functions serve` unable to see the worker
#   3. Absence of a green-path assertion for `dev sb flow` overall
# ══════════════════════════════════════════════════════════════════════

PROBE_SLUG="probe"
PROBE_WORKER_DIR="$SHARED_WT/supabase/functions/${PROBE_SLUG}-worker"

header "setup — fresh probe flow in feat-gamma (not released)"
cat > "$FEAT_WT/supabase/flows/${PROBE_SLUG}.ts" <<'TS'
import { Flow } from "@pgflow/dsl";

export const Probe = new Flow<{ value: string }>({
  slug: "probe",
}).step({ slug: "ping" }, (input) => ({ ok: true, value: input.run.value }));
TS
cat > "$FEAT_WT/supabase/flows/index.ts" <<'TS'
export { Noop } from "./noop.ts";
export { Mirror } from "./mirror.ts";
export { Probe } from "./probe.ts";
TS

# pgflow 0.14+ requires the ControlPlane edge function to be reachable
# during `npx pgflow compile`. The earlier guard scenario's trap did a
# `supabase stop && supabase start`, which dropped `supabase functions
# serve`. Re-spawn it now (match 03-db-reset's pattern). In normal dev
# use this is handled by `dev sb up` / `dev sb reset`.
header "start supabase functions serve (ControlPlane for pgflow compile)"
if ! pgrep -f 'supabase functions serve' >/dev/null 2>&1; then
  (cd "$SHARED_WT" && supabase functions serve) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
# Wait up to 30s for ControlPlane to respond. Skip-loop returns as soon
# as the endpoint is up so happy-path runs don't pay the full timeout.
CP_URL="http://localhost:54621/functions/v1/pgflow"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  curl -sf -o /dev/null -m 2 "$CP_URL" 2>/dev/null && break
  # 401/404 from a booted runtime is fine — it means HTTP reached it
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$CP_URL" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && break
  sleep 2
done

header "dev sb flow probe — compiles + scaffolds + syncs"
cd "$FEAT_WT"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow "$PROBE_SLUG" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" != "0" ]; then
  printf "${DIM}flow output (expected 0):${RESET}\n%s\n" "$OUTPUT" >&2
fi
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_not_contains "trap did not fire on success" "Restoring shared worktree" "$OUTPUT"

# Shared worktree retains the synced flow TS (trap-on-success kept it).
# If the trap fired on the success path, probe.ts would have been wiped
# and this assertion would fail.
assert_file_exists "shared wt has flows/probe.ts" \
  "$SHARED_WT/supabase/flows/${PROBE_SLUG}.ts"

# Shared worktree has the scaffolded worker dir — landed there via the
# post-scaffold rsync of supabase/functions/ (not just the invoking wt).
# If scaffold only wrote to the invoking worktree, these would be missing.
assert_file_exists "shared wt has functions/probe-worker/index.ts" \
  "$PROBE_WORKER_DIR/index.ts"
assert_file_exists "shared wt has functions/probe-worker/deno.json" \
  "$PROBE_WORKER_DIR/deno.json"

# Migration + worker-registration SQL are written to the invoking
# worktree by compile/scaffold, then symlinked into the shared wt by
# `dev sb flow` before `do_migrate_up` applies them.
PROBE_MIG=$(find "$SHARED_WT/supabase/migrations/jobs" \
  -maxdepth 1 -name "*_create_${PROBE_SLUG}_flow.sql" 2>/dev/null | head -n1)
PROBE_REG=$(find "$SHARED_WT/supabase/migrations/jobs" \
  -maxdepth 1 -name "*_register_${PROBE_SLUG}_worker.sql" 2>/dev/null | head -n1)

if [ -n "$PROBE_MIG" ]; then
  PASSED=$((PASSED + 1))
  printf "  ${GREEN}✓${RESET} probe flow migration present in shared wt ($(basename "$PROBE_MIG"))\n"
else
  FAILED=$((FAILED + 1))
  printf "  ${RED}✗${RESET} probe flow migration missing in shared wt\n"
fi

if [ -n "$PROBE_REG" ]; then
  PASSED=$((PASSED + 1))
  printf "  ${GREEN}✓${RESET} probe worker registration present in shared wt ($(basename "$PROBE_REG"))\n"
else
  FAILED=$((FAILED + 1))
  printf "  ${RED}✗${RESET} probe worker registration missing in shared wt\n"
fi

# ── Return to main for later cleanup ─────────────────────────────────

cd "$WORKTREE_BASE/main"

print_results
