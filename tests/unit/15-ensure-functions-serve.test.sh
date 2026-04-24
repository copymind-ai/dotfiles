#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: ensure_functions_serve${RESET}\n"

setup_tmpdir

# Shadow external commands the helpers require on PATH. `supabase` is touched
# during sourcing (the top-level `command -v` check); `docker` and `pgrep` are
# called inside `ensure_functions_serve` and are re-stubbed per-case by
# rewriting the stub scripts below.
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/supabase" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/supabase"
PATH="$STUB_BIN:$PATH"
export PATH

# A fake supabase worktree — just needs config.toml with project_id for
# get_project_id to read. The test doesn't touch the filesystem otherwise.
SB_WT="$TEST_TMPDIR/sb"
mkdir -p "$SB_WT/supabase"
cat > "$SB_WT/supabase/config.toml" <<'TOML'
project_id = "test-unit"
TOML

source "$SCRIPTS_DIR/dev-supabase-helpers.sh"

# Replace the spawn with a no-op that records invocations into a file.
# We redefine after sourcing so the real function is overridden without
# launching a real `supabase functions serve` background subshell.
SPAWN_LOG="$TEST_TMPDIR/spawn.log"
: > "$SPAWN_LOG"
_spawn_functions_serve() {
  echo "spawned:$1" >> "$SPAWN_LOG"
}

# Write docker + pgrep stubs on every case. Both emit behaviour based on
# state files we flip per-case, so we can simulate all four permutations
# without restarting the whole test harness.
CONTAINER_STATE="$TEST_TMPDIR/container.state"
HOST_STATE="$TEST_TMPDIR/host.state"

cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
# Only handle the 'docker ps --filter name=... --format {{.Names}}' call
# ensure_functions_serve makes. Anything else is ignored (exit 0).
if [ "\$1" = "ps" ]; then
  if [ "\$(cat "$CONTAINER_STATE" 2>/dev/null)" = "up" ]; then
    echo "supabase_edge_runtime_test-unit"
  fi
fi
exit 0
STUB
chmod +x "$STUB_BIN/docker"

cat > "$STUB_BIN/pgrep" <<STUB
#!/usr/bin/env bash
if [ "\$(cat "$HOST_STATE" 2>/dev/null)" = "up" ]; then
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/pgrep"

# Also stub pkill so the split-brain kill doesn't actually target anything.
cat > "$STUB_BIN/pkill" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/pkill"

# Reset state between cases.
_reset_state() {
  : > "$SPAWN_LOG"
  echo "$1" > "$CONTAINER_STATE"
  echo "$2" > "$HOST_STATE"
}

# ── both up → no-op, no spawn ────────────────────────────────────────
header "both up — reports 'already running', does not spawn"
_reset_state "up" "up"
OUTPUT=$(ensure_functions_serve "$SB_WT" 2>&1)

assert_contains "reports already running" "Edge functions already running" "$OUTPUT"
assert_not_contains "no 'Starting' message" "Starting edge functions" "$OUTPUT"
assert_eq "spawn not invoked" "" "$(cat "$SPAWN_LOG")"

# ── container up, host down → spawn fires ────────────────────────────
header "container up, host down — respawns host process"
_reset_state "up" "down"
OUTPUT=$(ensure_functions_serve "$SB_WT" 2>&1)

assert_contains "reports starting" "Starting edge functions" "$OUTPUT"
assert_eq "spawn invoked once with supabase wt" "spawned:$SB_WT" "$(cat "$SPAWN_LOG")"

# ── container down, host up → pkill + respawn (clean split-brain) ────
header "container down, host up — kills stale host + spawns fresh"
_reset_state "down" "up"
OUTPUT=$(ensure_functions_serve "$SB_WT" 2>&1)

assert_contains "reports starting" "Starting edge functions" "$OUTPUT"
assert_eq "spawn invoked once with supabase wt" "spawned:$SB_WT" "$(cat "$SPAWN_LOG")"

# ── both down → spawn fires ──────────────────────────────────────────
header "both down — cold start spawn"
_reset_state "down" "down"
OUTPUT=$(ensure_functions_serve "$SB_WT" 2>&1)

assert_contains "reports starting" "Starting edge functions" "$OUTPUT"
assert_eq "spawn invoked once with supabase wt" "spawned:$SB_WT" "$(cat "$SPAWN_LOG")"

print_results
