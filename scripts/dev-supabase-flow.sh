#!/usr/bin/env bash
set -euo pipefail

# Compile pgflow flows from the invoking worktree into SQL migrations under
# supabase/migrations/jobs/ (of the invoking worktree), apply them against the
# shared supabase stack.
#
# Usage:
#   dev sb flow              # compile all known flows
#   dev sb flow <slug>       # compile a specific flow
#
# Replaces scripts/db-flow-local.sh. Key differences:
#   - No strict edge-runtime anchor pre-check: the script rsyncs flows into
#     the shared worktree and then `supabase stop && supabase start` from the
#     shared worktree — which implicitly re-anchors the edge-runtime container
#     if it was previously started from a different worktree.
#   - Flow source is ALWAYS synced from the invoking worktree into the shared
#     worktree before compile, even when invoked from the shared worktree
#     (the previous script short-circuited in that case).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

# ── Parse args ───────────────────────────────────────────────────────
if [ $# -gt 1 ]; then
  echo "Usage: dev sb flow [slug]" >&2
  echo "  (too many arguments)" >&2
  exit 1
fi

INVOKING_WT="$(git rev-parse --show-toplevel)"
SUPABASE_WT="$(find_supabase_wt)"

# ── Sanity checks ────────────────────────────────────────────────────
INVOKING_FLOWS_DIR="$INVOKING_WT/supabase/flows"
SHARED_FLOWS_DIR="$SUPABASE_WT/supabase/flows"

if [ ! -d "$INVOKING_FLOWS_DIR" ]; then
  echo "Error: $INVOKING_FLOWS_DIR does not exist." >&2
  echo "  This worktree has no pgflow flows." >&2
  exit 1
fi

if [ ! -d "$SHARED_FLOWS_DIR" ]; then
  echo "Error: $SHARED_FLOWS_DIR does not exist." >&2
  echo "  The shared supabase worktree must have supabase/flows/. Run: dev sb up" >&2
  exit 1
fi

MIGRATIONS_DIR="$INVOKING_WT/supabase/migrations"
JOBS_DIR="$MIGRATIONS_DIR/jobs"
CONFIG_FILE="$INVOKING_WT/supabase/config.toml"

# Auto-discover flow slugs (each flow file has a literal `slug: "..."` line).
ALL_SLUGS=($(grep -h 'slug: "' "$INVOKING_FLOWS_DIR"/*.ts 2>/dev/null \
  | sed -E 's/.*slug: "([^"]+)".*/\1/' | sort -u))

if [ $# -eq 0 ]; then
  SLUGS=("${ALL_SLUGS[@]}")
  if [ ${#SLUGS[@]} -eq 0 ]; then
    echo "No flows found in $INVOKING_FLOWS_DIR"
    exit 0
  fi
  echo "==> Compiling all flows: ${SLUGS[*]}"
else
  SLUGS=("$1")
  echo "==> Compiling flow: $1"
fi

# ── Fetch origin/main to tell released flows from unreleased ones ────
echo "==> Fetching origin/main to check released-flow state"
if ! (cd "$INVOKING_WT" && git fetch origin main --quiet); then
  echo "Error: 'git fetch origin main' failed." >&2
  echo "  Needed to distinguish released flows (must be versioned) from unreleased ones." >&2
  exit 1
fi

# ── Helpers: camelCase → snake_case / kebab-case ─────────────────────
to_snake_case() {
  echo "$1" | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]'
}

to_kebab_case() {
  echo "$1" | sed 's/\([A-Z]\)/-\1/g' | sed 's/^-//' | tr '[:upper:]' '[:lower:]'
}

# ── Sync invoking worktree's flow source into shared worktree ────────
# Always sync — even when invoking from the shared worktree — so the behaviour
# is uniform: compile consumes the invoking worktree's source.
SHARED_JOB_KEY="$SUPABASE_WT/src/types/job-key.ts"
LOCAL_JOB_KEY="$INVOKING_WT/src/types/job-key.ts"

SHARED_FLOWS_BACKUP=$(mktemp -d)
echo "==> Backing up shared worktree's flows to $SHARED_FLOWS_BACKUP"
cp -a "$SHARED_FLOWS_DIR" "$SHARED_FLOWS_BACKUP/"
if [ -f "$SHARED_JOB_KEY" ]; then
  cp -a "$SHARED_JOB_KEY" "$SHARED_FLOWS_BACKUP/job-key.ts"
fi

restore_shared_flows() {
  echo ""
  echo "==> Restoring shared worktree's flows"
  rm -rf "$SHARED_FLOWS_DIR"
  mv "$SHARED_FLOWS_BACKUP/flows" "$SHARED_FLOWS_DIR"
  if [ -f "$SHARED_FLOWS_BACKUP/job-key.ts" ]; then
    mv "$SHARED_FLOWS_BACKUP/job-key.ts" "$SHARED_JOB_KEY"
  fi
  rm -rf "$SHARED_FLOWS_BACKUP"
  echo "==> Restarting supabase stack to re-read restored flows"
  (cd "$SUPABASE_WT" && supabase stop >/dev/null 2>&1 && supabase start >/dev/null 2>&1) || true
}
trap restore_shared_flows EXIT

echo "==> Syncing flow source from invoking worktree into shared worktree"
rsync -a --delete "$INVOKING_FLOWS_DIR/" "$SHARED_FLOWS_DIR/"
if [ -f "$LOCAL_JOB_KEY" ]; then
  mkdir -p "$(dirname "$SHARED_JOB_KEY")"
  cp -a "$LOCAL_JOB_KEY" "$SHARED_JOB_KEY"
fi

# Recreate the edge runtime so per-file bind mounts pick up new files.
echo "==> Restarting supabase stack from shared worktree (picks up new + changed flow files)"
API_PORT="$(awk '/^\[api\]/{f=1;next}/^\[/{f=0}f&&/^port[[:space:]]*=/{gsub(/[^0-9]/,"");print;exit}' "$SUPABASE_WT/supabase/config.toml")"
[ -z "$API_PORT" ] && API_PORT=54321
(cd "$SUPABASE_WT" && supabase stop >/dev/null 2>&1 && supabase start >/dev/null 2>&1) || true
wait_for_control_plane "$API_PORT"

# ── Pre-pass: validate each slug, decide what needs recompile ────────
TODO_SLUGS=()
for SLUG in "${SLUGS[@]}"; do
  SNAKE_SLUG=$(to_snake_case "$SLUG")
  KEBAB_SLUG=$(to_kebab_case "$SLUG")

  echo ""
  echo "==> Checking flow: $SLUG"

  SOURCE_FILE="$INVOKING_FLOWS_DIR/${KEBAB_SLUG}.ts"
  EXISTING_MIGRATION=$(find "$MIGRATIONS_DIR" \( -name "*_create_${SLUG}_flow.sql" -o -name "*_create_${SNAKE_SLUG}_flow.sql" \) 2>/dev/null | head -n 1)
  if [ -n "$EXISTING_MIGRATION" ] && [ -f "$SOURCE_FILE" ] && [ ! "$SOURCE_FILE" -nt "$EXISTING_MIGRATION" ]; then
    echo "    Up to date — skipping (source unchanged since $(basename "$EXISTING_MIGRATION"))"
    continue
  fi

  EXISTING_FILES=$(find "$MIGRATIONS_DIR" \( -name "*_create_${SLUG}_flow.sql" -o -name "*_create_${SNAKE_SLUG}_flow.sql" \) 2>/dev/null || true)
  RELEASED_BASENAME=$(cd "$INVOKING_WT" && git ls-tree -r --name-only origin/main -- supabase/migrations/jobs/ 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E "^[0-9]+_create_${SLUG}_flow\.sql$|^[0-9]+_create_${SNAKE_SLUG}_flow\.sql$" \
    | sort | tail -n1 || true)
  LOCAL_BASENAME=$(echo "$EXISTING_FILES" | xargs -n1 basename 2>/dev/null | sort | tail -n1 || true)

  if [ -n "$RELEASED_BASENAME" ] && [ "$RELEASED_BASENAME" = "$LOCAL_BASENAME" ]; then
    echo ""
    echo "Error: flow '$SLUG' is released on origin/main ($RELEASED_BASENAME)." >&2
    echo "  Rewriting a released flow's migration breaks other environments' history." >&2
    echo "  To change an already-released flow, create a new versioned flow:" >&2
    echo "    1. Copy supabase/flows/${KEBAB_SLUG}.ts -> supabase/flows/${KEBAB_SLUG}-v2.ts" >&2
    echo "    2. Change the slug in the new file (e.g. to '${SLUG}V2')" >&2
    echo "    3. Register it in supabase/flows/index.ts" >&2
    echo "    4. Update callers (UserJobKey + code) to use the new slug" >&2
    echo "    5. Re-run: dev sb flow" >&2
    echo "  See https://www.pgflow.dev/build/version-flows/" >&2
    exit 1
  fi

  TODO_SLUGS+=("$SLUG")
done

# ── Work pass ────────────────────────────────────────────────────────
PROJECT_ID="$(get_project_id "$SUPABASE_WT")"
COMPILED_ANY=false
for SLUG in ${TODO_SLUGS[@]+"${TODO_SLUGS[@]}"}; do
  SNAKE_SLUG=$(to_snake_case "$SLUG")
  KEBAB_SLUG=$(to_kebab_case "$SLUG")
  WORKER_NAME="${KEBAB_SLUG}-worker"

  echo ""
  echo "==> Recompiling flow: $SLUG"
  COMPILED_ANY=true

  OLD_FILES=$(find "$MIGRATIONS_DIR" \( -name "*_create_${SLUG}_flow.sql" -o -name "*_create_${SNAKE_SLUG}_flow.sql" \) 2>/dev/null || true)

  if [ -n "$OLD_FILES" ]; then
    OLD_VERSIONS=()
    while read -r f; do
      [ -z "$f" ] && continue
      bn=$(basename "$f")
      version="${bn%%_*}"
      OLD_VERSIONS+=("$version")
      echo "    Removing old migration: $bn"
      rm "$f"
    done <<< "$OLD_FILES"

    if [ ${#OLD_VERSIONS[@]} -gt 0 ]; then
      echo "    Repairing local DB history: ${OLD_VERSIONS[*]} => reverted"
      (cd "$SUPABASE_WT" && supabase migration repair --status reverted "${OLD_VERSIONS[@]}" --local) 2>/dev/null || \
        echo "    (warning: migration repair failed — continuing)"

      echo "    Resetting pgflow state for $SLUG (unreleased iteration)"
      docker exec -i "supabase_db_${PROJECT_ID}" \
        psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "SELECT pgflow.delete_flow_and_data('$SLUG');" >/dev/null 2>&1 \
        || echo "    (note: delete_flow_and_data failed — flow may not have been registered)"
    fi
  fi

  (cd "$INVOKING_WT" && npx pgflow compile "$SLUG")

  NEW_FILE=$(find "$MIGRATIONS_DIR" -maxdepth 1 \( -name "*_create_${SLUG}_flow.sql" -o -name "*_create_${SNAKE_SLUG}_flow.sql" \) 2>/dev/null || true)
  if [ -n "$NEW_FILE" ]; then
    mkdir -p "$JOBS_DIR"
    mv "$NEW_FILE" "$JOBS_DIR/"
    echo "    Moved to jobs/: $(basename "$NEW_FILE")"
  else
    echo "Error: Migration file not found after compile" >&2
    exit 1
  fi

  if ! grep -q "\[functions\.${WORKER_NAME}\]" "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "[functions.${WORKER_NAME}]" >> "$CONFIG_FILE"
    echo "verify_jwt = false" >> "$CONFIG_FILE"
    echo "    Added [functions.${WORKER_NAME}] to config.toml"
  fi

  scaffold_pgflow_worker "$INVOKING_WT" "$SUPABASE_WT" "$SLUG"

  if ! grep -rq "track_worker_function('${WORKER_NAME}')" "$JOBS_DIR"; then
    TIMESTAMP=$(date -u -v+1S +"%Y%m%d%H%M%S" 2>/dev/null || date -u -d "+1 second" +"%Y%m%d%H%M%S")
    REG_FILE="${JOBS_DIR}/${TIMESTAMP}_register_${SNAKE_SLUG}_worker.sql"
    cat > "$REG_FILE" <<SQL
-- Register Edge Function worker so pgflow's ensure_workers cron invokes it
SELECT pgflow.track_worker_function('${WORKER_NAME}');
SQL
    echo "    Created worker registration: $(basename "$REG_FILE")"
  fi
done

if [ "$COMPILED_ANY" = true ]; then
  echo ""
  echo "==> Applying migrations..."
  # Apply against the invoking worktree's migrations dir — dev sb link already
  # bridges unreleased migrations into the shared stack via symlinks. For a
  # flow just compiled in the invoking worktree, symlink it now and apply.
  if [ "$INVOKING_WT" != "$SUPABASE_WT" ]; then
    new_files="$(find_new_migrations "$INVOKING_WT" "$SUPABASE_WT")"
    if [ -n "$new_files" ]; then
      symlink_migrations "$INVOKING_WT" "$new_files" "$SUPABASE_WT"
    fi
  fi
  do_migrate_up "$SUPABASE_WT"
else
  echo ""
  echo "==> Nothing to apply — all flows up to date."
fi

echo ""
echo "==> Done!"
