#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: dev sb anchor${RESET}\n"

setup_tmpdir

# ── Stub external binaries ────────────────────────────────────────────
# `supabase` is required during dev-supabase-helpers.sh sourcing (top-level
# `command -v` check). `docker` and `git` are invoked by the anchor script
# itself; we record every call so the assertions can verify the full
# command sequence.
#
# Stubs honour two env knobs so individual cases can simulate failures
# without rewriting the stub between cases:
#   SUPABASE_STOP_EXIT   — exit code for `supabase stop` (default 0)
#   DOCKER_UPDATE_EXIT   — exit code for `docker update ...` (default 0)
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"

DOCKER_LOG="$TEST_TMPDIR/docker.log"
SUPABASE_LOG="$TEST_TMPDIR/supabase.log"
: > "$DOCKER_LOG"
: > "$SUPABASE_LOG"

cat > "$STUB_BIN/supabase" <<STUB
#!/usr/bin/env bash
echo "supabase \$*" >> "$SUPABASE_LOG"
if [ "\$1" = "stop" ]; then
  exit "\${SUPABASE_STOP_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$STUB_BIN/supabase"

# wait_for_control_plane curl-checks the ControlPlane edge function. In the
# unit test there is no real edge runtime, so stub curl to always succeed —
# otherwise the script would hang on the 30-iteration polling loop.
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/curl"

cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$DOCKER_LOG"
if [ "\$1" = "update" ]; then
  exit "\${DOCKER_UPDATE_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$STUB_BIN/docker"

PATH="$STUB_BIN:$PATH"
export PATH

# ── Build a bare repo + sibling worktrees ────────────────────────────
# The anchor script calls `git rev-parse --show-toplevel` to identify the
# invoking worktree, walks one dir up to find sibling worktrees + the
# .worktree-ports registry, and reads the shared `supabase` worktree's
# config.toml + .env.local. The script also enforces require_bare_repo,
# so the parent .git must actually be bare.
ROOT="$TEST_TMPDIR/copymind-app"
mkdir -p "$ROOT"
REGISTRY="$ROOT/.worktree-ports"

# Initialize a tiny upstream so the bare clone has at least one commit
# (worktree creation needs an existing branch).
SEED_DIR="$TEST_TMPDIR/_seed"
mkdir -p "$SEED_DIR"
(cd "$SEED_DIR" && git init -q -b main && git config user.email t@t && git config user.name t \
   && touch f && git add f && git commit -q -m init)

BARE_REPO="$ROOT/repo.git"
git clone --bare -q "$SEED_DIR" "$BARE_REPO"

INVOKING_WT="$ROOT/main"
SHARED_WT="$ROOT/supabase"
git -C "$BARE_REPO" worktree add -q --detach "$INVOKING_WT" main
git -C "$BARE_REPO" worktree add -q --detach "$SHARED_WT" main

mkdir -p "$SHARED_WT/supabase"

cat > "$SHARED_WT/supabase/config.toml" <<TOML
project_id = "copymind-app"

[api]
port = 54321
TOML

# Helper to reset .env.local between cases so each test starts from a
# known mismatched state (current value 3000 vs. desired 3008).
reset_env_file() {
  cat > "$SHARED_WT/.env.local" <<ENV
SOME_OTHER=preserved
COPYMIND_API_HOST=http://host.docker.internal:3000
ANOTHER=alsopreserved
ENV
}
reset_env_file

cat > "$REGISTRY" <<REG
# worktree	port	created
main	3008	2026-04-06
slack-mcp	3009	2026-04-28
REG

ANCHOR_SCRIPT="$SCRIPTS_DIR/dev-supabase-anchor.sh"

# ── Case 1: registry missing ──────────────────────────────────────────
header "fails when port registry is missing"
mv "$REGISTRY" "$REGISTRY.bak"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?
mv "$REGISTRY.bak" "$REGISTRY"

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "mentions registry" ".worktree-ports" "$OUTPUT"

# ── Case 2: invoking worktree absent from registry ────────────────────
header "fails when current worktree is not in registry"
mv "$INVOKING_WT" "$ROOT/unregistered"
EXIT_CODE=0
OUTPUT=$(cd "$ROOT/unregistered" && bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?
mv "$ROOT/unregistered" "$INVOKING_WT"

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "names the missing worktree" "unregistered" "$OUTPUT"

# ── Case 3: shared supabase worktree absent ───────────────────────────
header "fails when shared supabase worktree is missing"
mv "$SHARED_WT" "$SHARED_WT.bak"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?
mv "$SHARED_WT.bak" "$SHARED_WT"

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "mentions supabase worktree" "supabase" "$OUTPUT"

# ── Case 4: happy path ────────────────────────────────────────────────
header "happy path — updates env, recreates container, applies restart policy"
reset_env_file
: > "$DOCKER_LOG"
: > "$SUPABASE_LOG"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?

assert_exit_code "exits with 0" "0" "$EXIT_CODE"

# .env.local contents — COPYMIND_API_HOST updated, neighbours preserved
ENV_CONTENT="$(cat "$SHARED_WT/.env.local")"
assert_contains "COPYMIND_API_HOST points at invoking worktree port" \
  "COPYMIND_API_HOST=http://host.docker.internal:3008" "$ENV_CONTENT"
assert_contains "preserves SOME_OTHER" "SOME_OTHER=preserved" "$ENV_CONTENT"
assert_contains "preserves ANOTHER" "ANOTHER=alsopreserved" "$ENV_CONTENT"

# Single COPYMIND_API_HOST line — no duplicates
COUNT=$(grep -c "^COPYMIND_API_HOST=" "$SHARED_WT/.env.local")
assert_eq "exactly one COPYMIND_API_HOST line" "1" "$COUNT"

# Recreation goes through a full `supabase stop` + `supabase start` cycle
# (NOT `docker restart`, which would reuse the container's frozen env).
# Both commands run from the shared worktree so the freshly-rewritten
# .env.local is what gets baked into the new edge runtime container.
SUPABASE_CALLS="$(cat "$SUPABASE_LOG")"
assert_contains "stops the stack" "supabase stop" "$SUPABASE_CALLS"
assert_contains "restarts the stack" "supabase start" "$SUPABASE_CALLS"

# Docker is only used to apply the restart policy on the recreated
# container (idempotent, survives future OOM kills).
DOCKER_CALLS="$(cat "$DOCKER_LOG")"
assert_contains "applies unless-stopped policy" \
  "update --restart unless-stopped supabase_edge_runtime_copymind-app" "$DOCKER_CALLS"
assert_contains "announces restart policy on success" "restart policy: unless-stopped" "$OUTPUT"

# ── Case 5: idempotent — value already correct, stack cycle skipped ───
header "idempotent — re-running with matching env skips stack cycle"
# After Case 4 the env file is already at port 3008. A re-run should
# notice the value is unchanged and skip the costly supabase stop/start
# (the cycle takes ~10s and drops every connection running workers hold).
# Restart policy still gets re-applied because it's cheap and idempotent.
: > "$DOCKER_LOG"
: > "$SUPABASE_LOG"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?

assert_exit_code "exits with 0" "0" "$EXIT_CODE"
COUNT=$(grep -c "^COPYMIND_API_HOST=" "$SHARED_WT/.env.local")
assert_eq "still exactly one COPYMIND_API_HOST line" "1" "$COUNT"

SUPABASE_CALLS="$(cat "$SUPABASE_LOG")"
assert_not_contains "did not stop the stack" "supabase stop" "$SUPABASE_CALLS"
assert_not_contains "did not start the stack" "supabase start" "$SUPABASE_CALLS"
assert_contains "tells the user it skipped" "env unchanged" "$OUTPUT"

DOCKER_CALLS="$(cat "$DOCKER_LOG")"
assert_contains "still applies restart policy on no-op" \
  "update --restart unless-stopped" "$DOCKER_CALLS"

# ── Case 6: supabase stop fails — start must still run ────────────────
header "stop returning nonzero does not skip start (set -e short-circuit fix)"
# Regression coverage: previously the script chained the two with `&&`,
# so a non-zero stop (down stack, half-up state) would skip start under
# `set -e` and exit the script with no anchor applied.
reset_env_file
: > "$DOCKER_LOG"
: > "$SUPABASE_LOG"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && SUPABASE_STOP_EXIT=1 bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?

assert_exit_code "exits with 0 even though stop failed" "0" "$EXIT_CODE"
SUPABASE_CALLS="$(cat "$SUPABASE_LOG")"
assert_contains "still attempted stop" "supabase stop" "$SUPABASE_CALLS"
assert_contains "ran start despite stop failure" "supabase start" "$SUPABASE_CALLS"

# ── Case 7: docker update fails — warns instead of lying ──────────────
header "docker update failure surfaces a warning"
# Regression coverage: previously a failed `docker update` was swallowed
# by `|| true` and the script unconditionally printed
# "restart policy: unless-stopped", lying about the outcome.
reset_env_file
: > "$DOCKER_LOG"
: > "$SUPABASE_LOG"
EXIT_CODE=0
OUTPUT=$(cd "$INVOKING_WT" && DOCKER_UPDATE_EXIT=1 bash "$ANCHOR_SCRIPT" 2>&1) || EXIT_CODE=$?

assert_exit_code "exits with 0" "0" "$EXIT_CODE"
assert_contains "warns about failed update" "could not apply restart=unless-stopped" "$OUTPUT"
assert_not_contains "does not falsely announce success" \
  "restart policy: unless-stopped" "$OUTPUT"

print_results
