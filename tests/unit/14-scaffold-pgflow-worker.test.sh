#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: scaffold_pgflow_worker${RESET}\n"

setup_tmpdir

# Shadow `supabase` on PATH so sourcing dev-supabase-helpers.sh doesn't abort.
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/supabase" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/supabase"
PATH="$STUB_BIN:$PATH"
export PATH

source "$SCRIPTS_DIR/dev-supabase-helpers.sh"

_make_flow_wt() {
  local wt="$1" kebab="$2" export_name="$3"
  mkdir -p "$wt/supabase/flows"
  cat > "$wt/supabase/flows/${kebab}.ts" <<TS
import { Flow } from "@pgflow/dsl";

export const ${export_name} = new Flow<{ value: string }>({
  slug: "placeholder",
}).step({ slug: "noop" }, (input) => ({ value: input.run.value }));
TS
}

_make_supabase_wt() {
  local wt="$1" version="${2:-}"
  if [ -n "$version" ]; then
    mkdir -p "$wt/supabase/functions/pgflow"
    cat > "$wt/supabase/functions/pgflow/deno.json" <<JSON
{
  "imports": {
    "@pgflow/edge-worker": "jsr:@pgflow/edge-worker@${version}",
    "@pgflow/edge-worker/": "jsr:@pgflow/edge-worker@${version}/",
    "@pgflow/dsl": "npm:@pgflow/dsl@${version}",
    "@pgflow/dsl/": "npm:@pgflow/dsl@${version}/"
  }
}
JSON
  else
    mkdir -p "$wt/supabase"
  fi
}

# ── happy path: both files rendered with version from supabase wt ────
header "pins version from supabase wt's pgflow/deno.json"
FEAT_WT="$TEST_TMPDIR/feat-happy"
SB_WT="$TEST_TMPDIR/sb-happy"
_make_flow_wt "$FEAT_WT" "twin-sleep" "TwinSleep"
_make_supabase_wt "$SB_WT" "0.15.2"

OUTPUT=$(scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "twinSleep" 2>&1)

WORKER_DIR="$FEAT_WT/supabase/functions/twin-sleep-worker"
assert_file_exists "worker dir created" "$WORKER_DIR"
assert_file_exists "index.ts written" "$WORKER_DIR/index.ts"
assert_file_exists "deno.json written" "$WORKER_DIR/deno.json"
assert_contains "index.ts imports EdgeWorker" "from \"@pgflow/edge-worker\"" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts uses real export name" "import { TwinSleep }" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts imports from kebab path" "../../flows/twin-sleep.ts" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts starts worker with export" "EdgeWorker.start(TwinSleep)" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "deno.json uses version from supabase wt" "@pgflow/dsl@0.15.2" "$(cat "$WORKER_DIR/deno.json")"
assert_contains "log reports version" "pgflow@0.15.2" "$OUTPUT"

# ── version fallback when supabase wt has no pgflow/deno.json ───────
header "falls back to 0.14.1 when supabase wt has no pgflow function"
FEAT_WT="$TEST_TMPDIR/feat-no-sb"
SB_WT="$TEST_TMPDIR/sb-empty"
_make_flow_wt "$FEAT_WT" "build-facts-map" "BuildFactsMap"
_make_supabase_wt "$SB_WT"

scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "buildFactsMap" >/dev/null 2>&1

assert_contains "deno.json uses fallback version" "@pgflow/edge-worker@0.14.1" \
  "$(cat "$FEAT_WT/supabase/functions/build-facts-map-worker/deno.json")"

# ── feature wt's own package.json is NOT consulted ───────────────────
header "ignores feature worktree's package.json"
FEAT_WT="$TEST_TMPDIR/feat-distractor"
SB_WT="$TEST_TMPDIR/sb-distractor"
_make_flow_wt "$FEAT_WT" "distract" "Distract"
# A distractor pgflow dep in the feature wt's package.json — must NOT leak through.
cat > "$FEAT_WT/package.json" <<'JSON'
{ "dependencies": { "@pgflow/dsl": "^9.9.9" } }
JSON
_make_supabase_wt "$SB_WT" "0.14.1"

scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "distract" >/dev/null 2>&1

DENO_JSON="$(cat "$FEAT_WT/supabase/functions/distract-worker/deno.json")"
assert_contains "uses supabase wt version" "@pgflow/dsl@0.14.1" "$DENO_JSON"
assert_not_contains "does not pick up feature wt version" "9.9.9" "$DENO_JSON"

# ── export-name fallback when no 'export const … = new Flow' found ──
header "falls back to PascalCase slug when no matching export"
FEAT_WT="$TEST_TMPDIR/feat-noexport"
SB_WT="$TEST_TMPDIR/sb-noexport"
mkdir -p "$FEAT_WT/supabase/flows"
# Flow file without the expected pattern — e.g. renamed export
cat > "$FEAT_WT/supabase/flows/mystery.ts" <<'TS'
import { Flow } from "@pgflow/dsl";
const Internal = new Flow<{}>({ slug: "mystery" });
export { Internal as Default };
TS
_make_supabase_wt "$SB_WT" "0.14.1"

OUTPUT=$(scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "mystery" 2>&1)

assert_contains "warns about fallback" "falling back to Mystery" "$OUTPUT"
assert_contains "index.ts imports PascalCase-derived name" "import { Mystery }" \
  "$(cat "$FEAT_WT/supabase/functions/mystery-worker/index.ts")"

# ── idempotent: existing worker dir left untouched ──────────────────
header "skips when worker dir already exists"
FEAT_WT="$TEST_TMPDIR/feat-exists"
SB_WT="$TEST_TMPDIR/sb-exists"
_make_flow_wt "$FEAT_WT" "noop" "Noop"
_make_supabase_wt "$SB_WT" "0.14.1"

# Pre-create a worker dir with sentinel content
mkdir -p "$FEAT_WT/supabase/functions/noop-worker"
echo "// user-customized" > "$FEAT_WT/supabase/functions/noop-worker/index.ts"

OUTPUT=$(scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "noop" 2>&1)

assert_eq "scaffold is silent on skip" "" "$OUTPUT"
assert_eq "user file untouched" "// user-customized" \
  "$(cat "$FEAT_WT/supabase/functions/noop-worker/index.ts")"
assert_file_not_exists "deno.json not created" "$FEAT_WT/supabase/functions/noop-worker/deno.json"

# ── warn + skip when flow source file is missing ────────────────────
header "warns and skips when flow source absent"
FEAT_WT="$TEST_TMPDIR/feat-no-source"
SB_WT="$TEST_TMPDIR/sb-no-source"
mkdir -p "$FEAT_WT/supabase/flows"
_make_supabase_wt "$SB_WT" "0.14.1"

OUTPUT=$(scaffold_pgflow_worker "$FEAT_WT" "$SB_WT" "ghost" 2>&1)

assert_contains "warns about missing source" "ghost.ts missing" "$OUTPUT"
assert_file_not_exists "no worker dir created" "$FEAT_WT/supabase/functions/ghost-worker"

print_results
