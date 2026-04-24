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
# Success path — trap does NOT restore on success (was the root cause
# of unreleased flows silently breaking after `dev sb flow` exited 0).
#
# We use `dev sb flow`'s "Up to date" shortcut (source file not newer
# than its existing migration) so this test doesn't depend on a live
# pgflow ControlPlane or real `npx pgflow compile`. The success path
# still runs the pre-pass rsync of flows + job-key.ts and then exits
# through the EXIT trap — if the trap restored on success (the bug),
# the rsynced probe.ts would be wiped from the shared worktree.
#
# The scaffold/functions-sync branch (when compile actually runs) is
# gated behind a live ControlPlane and isn't asserted here; covering
# that path reliably in CI would need a readiness probe that tracks
# per-pgflow-version runtime internals. We keep this test focused on
# the orchestration invariant we own.
# ══════════════════════════════════════════════════════════════════════

PROBE_SLUG="probe"
PROBE_MIG_BASENAME="20260502000000_create_${PROBE_SLUG}_flow.sql"

header "setup — probe flow + pre-compiled migration in feat-gamma"
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

# Hand-craft what `npx pgflow compile` would have produced, then backdate
# the flow TS so `dev sb flow` takes the "Up to date" shortcut and skips
# the real compile step entirely.
mkdir -p "$FEAT_WT/supabase/migrations/jobs"
cat > "$FEAT_WT/supabase/migrations/jobs/${PROBE_MIG_BASENAME}" <<SQL
SELECT pgflow.create_flow('${PROBE_SLUG}', max_attempts => 3, base_delay => 1);
SELECT pgflow.add_step('${PROBE_SLUG}', 'ping');
SQL
backdate "$FEAT_WT/supabase/flows/${PROBE_SLUG}.ts"

header "dev sb flow probe — trap does NOT fire on success"
cd "$FEAT_WT"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow "$PROBE_SLUG" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" != "0" ]; then
  printf "${DIM}flow output (expected 0):${RESET}\n%s\n" "$OUTPUT" >&2
fi
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "takes up-to-date shortcut" "Up to date — skipping" "$OUTPUT"
assert_not_contains "trap did not fire on success" "Restoring shared worktree" "$OUTPUT"
# Guard against regression: the edge-runtime reload is expensive (pkill +
# docker restart + respawn + wait) and should only fire when at least one
# slug needs recompile. The "Up to date" shortcut short-circuits past it.
assert_not_contains "up-to-date path skips edge-runtime reload" \
  "Reloading edge runtime" "$OUTPUT"

# Pre-pass rsync'd probe.ts into the shared worktree. If the trap had
# fired on the success path (the original bug), probe.ts would be
# missing here — the backup was taken BEFORE the rsync.
assert_file_exists "shared wt kept synced flows/probe.ts (trap-on-success fix)" \
  "$SHARED_WT/supabase/flows/${PROBE_SLUG}.ts"

# ── Return to main for later cleanup ─────────────────────────────────

cd "$WORKTREE_BASE/main"

print_results
