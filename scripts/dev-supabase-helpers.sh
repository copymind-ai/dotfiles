#!/usr/bin/env bash
# Shared helpers for dev-supabase-*.sh scripts. Source this, don't execute.

# --- Require supabase CLI ---
if ! command -v supabase &>/dev/null; then
  echo "Error: supabase CLI not found. Install via: brew install supabase/tap/supabase" >&2
  exit 1
fi

require_bare_repo() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir)"
  if ! git -C "$git_common_dir" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
    echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
    exit 1
  fi
}

supabase_is_running() {
  # Check Docker for the db container rather than `supabase status`, which
  # exits non-zero whenever any container is unhealthy/restarting — that
  # made `dev sb down` refuse to stop a broken stack.
  local supabase_wt project_id
  supabase_wt="$(resolve_supabase_wt 2>/dev/null)" || return 1
  [ -f "$supabase_wt/supabase/config.toml" ] || return 1
  project_id="$(get_project_id "$supabase_wt")"
  [ -n "$project_id" ] || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "supabase_db_${project_id}"
}

resolve_supabase_wt() {
  local current_wt parent_dir
  current_wt="$(git rev-parse --show-toplevel)"
  parent_dir="$(cd "$current_wt/.." && pwd)"
  echo "$parent_dir/supabase"
}

ensure_fetch_refspec() {
  if ! git config --get remote.origin.fetch &>/dev/null; then
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  fi
}

# --- Colors ---
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# --- Migration helpers ---

find_supabase_wt() {
  local wt_path=""
  wt_path=$(git worktree list --porcelain | awk '/^worktree .*\/supabase$/ { print substr($0, 10) }')
  if [ -z "$wt_path" ]; then
    echo "Error: Supabase worktree not found. Run: dev sb up" >&2
    return 1
  fi
  echo "$wt_path"
}

find_new_migrations() {
  local wt_path="$1"
  local supabase_wt="$2"
  local dir basename_f
  for dir in app jobs; do
    local wt_dir="$wt_path/supabase/migrations/$dir"
    local sb_dir="$supabase_wt/supabase/migrations/$dir"
    [ -d "$wt_dir" ] || continue
    for f in "$wt_dir"/*.sql; do
      [ -f "$f" ] || continue
      basename_f="$(basename "$f")"
      if [ -f "$sb_dir/$basename_f" ] && [ ! -L "$sb_dir/$basename_f" ]; then
        continue
      fi
      if [ -L "$sb_dir/$basename_f" ]; then
        local target
        target="$(realpath "$sb_dir/$basename_f" 2>/dev/null || true)"
        if [ "$target" = "$(realpath "$f")" ]; then
          continue
        fi
      fi
      echo "supabase/migrations/$dir/$basename_f"
    done
  done
}

get_latest_origin_timestamp() {
  local supabase_wt="$1"
  find "$supabase_wt/supabase/migrations" -name "*.sql" ! -type l -print0 2>/dev/null \
    | xargs -0 -I{} basename {} \
    | sed 's/_.*//' \
    | sort -n \
    | tail -1
}

check_timestamps() {
  local wt_name="$1"
  local new_files="$2"
  local latest_origin_ts="$3"
  local supabase_wt="$4"

  if [ -z "$latest_origin_ts" ]; then
    return 0
  fi

  local outdated=()
  local file ts basename_f
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    basename_f="$(basename "$file")"
    ts="${basename_f%%_*}"
    if [ "$ts" -le "$latest_origin_ts" ] 2>/dev/null; then
      outdated+=("$basename_f")
    fi
  done <<< "$new_files"

  if [ ${#outdated[@]} -eq 0 ]; then
    return 0
  fi

  local origin_migrations=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    origin_migrations+=("$f")
  done < <(find "$supabase_wt/supabase/migrations" -name "*.sql" ! -type l -exec basename {} \; 2>/dev/null | sort)

  local earliest_outdated_ts
  earliest_outdated_ts="${outdated[0]%%_*}"
  for o in "${outdated[@]}"; do
    local o_ts="${o%%_*}"
    if [ "$o_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      earliest_outdated_ts="$o_ts"
    fi
  done

  echo ""
  printf "${RED}\"$wt_name\" has migrations with outdated timestamps:${RESET}\n"
  echo ""

  local context_shown=0
  for m in "${origin_migrations[@]}"; do
    local m_ts="${m%%_*}"
    if [ "$m_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      context_shown=$((context_shown + 1))
    fi
  done

  local skip=$((context_shown - 2))
  if [ "$skip" -lt 0 ]; then skip=0; fi

  local shown=0
  local in_context=false
  for m in "${origin_migrations[@]}"; do
    local m_ts="${m%%_*}"
    if [ "$m_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      shown=$((shown + 1))
      if [ "$shown" -le "$skip" ]; then
        if [ "$in_context" = false ]; then
          printf "  ${DIM}...${RESET}\n"
          in_context=true
        fi
        continue
      fi
      in_context=false
      printf "  ${DIM}- %s${RESET}\n" "$m"
    else
      printf "  ${GREEN}- %s  (origin/main)${RESET}\n" "$m"
    fi
  done

  for o in "${outdated[@]}"; do
    printf "  ${RED}- %s  (%s, outdated timestamp)${RESET}\n" "$o" "$wt_name"
  done

  echo ""
  echo "Fix: rebase $wt_name onto origin/main to update migration timestamps"
  echo ""
  return 1
}

symlink_migrations() {
  local wt_path="$1"
  local new_files="$2"
  local supabase_wt="$3"

  local file link_path target_path basename_f
  local count=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    basename_f="$(basename "$file")"
    target_path="$wt_path/$file"
    link_path="$supabase_wt/$file"

    if [ -L "$link_path" ]; then
      local existing_target
      existing_target="$(realpath "$link_path" 2>/dev/null || readlink "$link_path")"
      if [ "$existing_target" != "$target_path" ]; then
        echo "Error: $basename_f already symlinked from a different worktree:" >&2
        echo "  Existing: $existing_target" >&2
        echo "  New:      $target_path" >&2
        return 1
      fi
      continue
    fi

    ln -s "$target_path" "$link_path"
    count=$((count + 1))
  done <<< "$new_files"

  if [ "$count" -gt 0 ]; then
    echo "Symlinked $count migration(s) into the supabase worktree"
  fi
}

remove_wt_symlinks() {
  local wt_path="$1"
  local supabase_wt="$2"

  local count=0
  local f resolved
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -L "$f" ]; then
        resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
        if [[ "$resolved" == "$wt_path/"* ]]; then
          rm "$f"
          count=$((count + 1))
        fi
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count symlink(s) from the supabase worktree"
  fi
}

clean_stale_symlinks() {
  local wt_path="$1"
  local supabase_wt="$2"

  local count=0
  local f resolved
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
      if [[ "$resolved" == "$wt_path/"* ]] && [ ! -f "$resolved" ]; then
        rm "$f"
        count=$((count + 1))
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count stale symlink(s) from the supabase worktree"
  fi
}

clean_all_stale_symlinks() {
  local supabase_wt="$1"

  local count=0
  local f
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      if [ ! -f "$(realpath "$f" 2>/dev/null || readlink "$f")" ]; then
        rm "$f"
        count=$((count + 1))
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count stale symlink(s) from the supabase worktree"
  else
    echo "No stale symlinks found"
  fi
}

# --- Config.toml parsers ---

get_project_id() {
  local supabase_wt="$1"
  sed -n 's/^project_id = "\(.*\)"/\1/p' "$supabase_wt/supabase/config.toml" | head -n 1
}

get_db_port() {
  local supabase_wt="$1"
  awk '
    /^\[db\]/ { in_db = 1; next }
    /^\[/ { in_db = 0 }
    in_db && /^port[[:space:]]*=/ { gsub(/[^0-9]/, ""); print; exit }
  ' "$supabase_wt/supabase/config.toml"
}

edge_runtime_enabled() {
  local supabase_wt="$1"
  awk '
    /^\[edge_runtime\]/ { in_er = 1; next }
    /^\[/ { in_er = 0 }
    in_er && /^enabled[[:space:]]*=/ { gsub(/[[:space:]]|"/, ""); sub(/.*=/, ""); print; exit }
  ' "$supabase_wt/supabase/config.toml"
}

# --- Migration + seed engines ---

# Flatten supabase/migrations/<subdir>/*.sql into a flat dir, run `supabase
# migration up`, restore the subdir layout — always, even on failure.
# Required because the Supabase CLI tracks migrations in one history table
# and expects a flat migrations directory.
do_migrate_up() {
  local supabase_wt="$1"
  local db_port
  db_port="$(get_db_port "$supabase_wt")"
  if [ -z "$db_port" ]; then
    echo "Error: could not read [db] port from $supabase_wt/supabase/config.toml" >&2
    return 1
  fi

  local migrations_dir="$supabase_wt/supabase/migrations"
  if [ ! -d "$migrations_dir" ]; then
    echo "No migrations directory — nothing to apply."
    return 0
  fi

  # Run the flatten + migrate + restore inside a subshell so the EXIT trap
  # always fires (covers success, failure, and caller-side errexit).
  (
    cd "$supabase_wt"
    local rel="supabase/migrations"
    local split="${rel}_split"
    local flat="${rel}_flat"

    local has_subdirs=false
    local entry
    for entry in "$rel"/*/; do
      [ -d "$entry" ] && { has_subdirs=true; break; }
    done

    if [ "$has_subdirs" = true ]; then
      mkdir -p "$flat"
      local project_dir
      for project_dir in "$rel"/*/; do
        cp "$project_dir"*.sql "$flat/" 2>/dev/null || true
      done
      mv "$rel" "$split"
      mv "$flat" "$rel"
      # shellcheck disable=SC2064
      trap "rm -rf '$rel'; mv '$split' '$rel'" EXIT
    fi

    # supabase_admin (superuser) so event triggers can be created.
    supabase migration up --db-url "postgresql://supabase_admin:postgres@127.0.0.1:${db_port}/postgres"
  )
}

# Iterate $supabase_wt/supabase/seeds/*.sql. Maintain a supabase_seeds.applied_seeds
# table keyed by filename. Skip users.sql (handled by `supabase db reset`).
do_seed_up() {
  local supabase_wt="$1"
  local db_port
  db_port="$(get_db_port "$supabase_wt")"
  if [ -z "$db_port" ]; then
    echo "Error: could not read [db] port from $supabase_wt/supabase/config.toml" >&2
    return 1
  fi
  local db_url="postgresql://postgres:postgres@127.0.0.1:${db_port}/postgres"
  local seeds_dir="$supabase_wt/supabase/seeds"

  if [ ! -d "$seeds_dir" ]; then
    echo "No seeds directory — nothing to apply."
    return 0
  fi

  psql "$db_url" -q -c "
CREATE SCHEMA IF NOT EXISTS supabase_seeds;
CREATE TABLE IF NOT EXISTS supabase_seeds.applied_seeds (
  name TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
" >/dev/null

  local applied=0 skipped=0
  local seed_file basename_f already
  for seed_file in "$seeds_dir"/*.sql; do
    [ -f "$seed_file" ] || continue
    basename_f="$(basename "$seed_file")"
    if [ "$basename_f" = "users.sql" ]; then
      continue
    fi
    already=$(psql -t -A "$db_url" -c "SELECT 1 FROM supabase_seeds.applied_seeds WHERE name = '$basename_f';" 2>/dev/null)
    if [ "$already" = "1" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    echo "Seeding $basename_f..."
    psql "$db_url" -q -f "$seed_file"
    psql "$db_url" -q -c "INSERT INTO supabase_seeds.applied_seeds (name) VALUES ('$basename_f');"
    applied=$((applied + 1))
  done

  echo "Seeds complete: $applied applied, $skipped already up to date."
}

# --- Edge runtime helpers ---

# Poll the pgflow ControlPlane endpoint until it responds or times out.
# Used by dev-supabase-flow.sh after restarting the stack.
wait_for_control_plane() {
  local port="${1:-54321}"
  local url="http://127.0.0.1:${port}/functions/v1/pgflow"
  echo -n "Waiting for ControlPlane"
  local i
  for i in $(seq 1 30); do
    if curl -s --max-time 2 "$url" >/dev/null 2>&1; then
      echo " ready!"
      return 0
    fi
    if [ "$i" -eq 30 ]; then
      echo " TIMEOUT"
      echo "Error: ControlPlane did not respond within 30 seconds" >&2
      return 1
    fi
    echo -n "."
    sleep 1
  done
}

# --- Retry with progressive backoff -----------------------------------
#
# Generic retry wrapper for flaky Supabase/Docker operations. Backoff
# grows linearly: 15s, 20s, 25s, 30s ... (10 + attempt * 5).
#
# Usage:
#   retry_with_backoff <max_attempts> <label> <command> [args...]
#
# The command is invoked via "$@" — pass a function name (or an external
# command). Inside an `if`, errexit is suspended, so a non-zero return
# from the command is captured rather than terminating the caller.
retry_with_backoff() {
  local max_attempts="$1"; shift
  local label="$1"; shift
  local attempts=0
  while true; do
    attempts=$((attempts + 1))
    if "$@"; then
      return 0
    fi
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "Error: $label failed after $max_attempts attempts" >&2
      return 1
    fi
    local backoff=$((10 + attempts * 5))
    echo "  (attempt $attempts/$max_attempts failed — retrying in ${backoff}s)"
    sleep "$backoff"
  done
}

# Run `supabase db reset --local` inside the supabase worktree, retrying
# with progressive backoff. `supabase db reset --local` restarts
# containers to clear PostgREST/edge-runtime caches; Kong can return a
# transient 502 if it health-checks an upstream before it's fully back
# up, so we retry up to 5 times.
#
# All scripts that need to reset the local DB MUST use this helper
# rather than calling `supabase db reset` directly.
#
# Usage: supabase_db_reset_with_retry <supabase_wt>
supabase_db_reset_with_retry() {
  local supabase_wt="$1"
  _supabase_db_reset_once() {
    (cd "$supabase_wt" && supabase db reset --local)
  }
  retry_with_backoff 5 "supabase db reset --local" _supabase_db_reset_once
}

# Restart the Supabase stack (`supabase stop && supabase start`) and
# wait for the pgflow ControlPlane edge function to respond. Each
# attempt gives ControlPlane up to 30s (wait_for_control_plane) to come
# up; up to 3 attempts with progressive backoff to absorb slow Docker
# warm-up on macOS.
#
# Usage: supabase_stack_restart_ready <supabase_wt> <api_port>
supabase_stack_restart_ready() {
  local supabase_wt="$1"
  local api_port="$2"
  _supabase_stack_restart_ready_once() {
    (cd "$supabase_wt" && supabase stop >/dev/null 2>&1 && supabase start >/dev/null 2>&1) || return 1
    wait_for_control_plane "$api_port"
  }
  retry_with_backoff 3 "supabase stack restart" _supabase_stack_restart_ready_once
}

# --- Migration application wrapper ---

apply_migrations() {
  local supabase_wt="$1"
  echo "Applying migrations from supabase worktree..."
  do_migrate_up "$supabase_wt"
}

unlink_worktree_migrations() {
  local wt_path="$1"

  local supabase_wt
  supabase_wt="$(find_supabase_wt 2>/dev/null)" || {
    echo "Supabase worktree not found, skipping symlink cleanup."
    return 0
  }

  # Collect versions from this worktree's symlinks before removing them
  local versions=()
  local f resolved basename_f version
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
      if [[ "$resolved" == "$wt_path/"* ]]; then
        basename_f="$(basename "$f")"
        version="${basename_f%%_*}"
        versions+=("$version")
      fi
    done
  done

  remove_wt_symlinks "$wt_path" "$supabase_wt"

  # Repair migration history
  if [ ${#versions[@]} -gt 0 ]; then
    local project_id
    project_id="$(sed -n 's/^project_id = "\(.*\)"/\1/p' "$supabase_wt/supabase/config.toml")"
    local db_container="supabase_db_${project_id}"

    local version_list
    version_list=$(printf "'%s'," "${versions[@]}")
    version_list="${version_list%,}"

    echo "Repairing migration history: ${versions[*]} => reverted"
    docker exec -e PGPASSWORD=postgres "$db_container" \
      psql -U supabase_admin -d postgres -c \
      "DELETE FROM supabase_migrations.schema_migrations WHERE version IN ($version_list);" \
      2>/dev/null || echo "  (warning: migration repair failed — continuing)"
  fi

  if supabase_is_running; then
    echo "Updating supabase worktree to origin/main..."
    git fetch origin
    (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
    apply_migrations "$supabase_wt"
  fi
}

# Scaffold a pgflow Deno edge-function worker from templates. Idempotent: if
# the worker directory already exists, returns without touching it.
#
# Usage: scaffold_pgflow_worker <invoking_wt> <supabase_wt> <slug>
#
# Expects supabase/flows/<kebab-slug>.ts to exist in the invoking worktree.
# Templates live under scripts/templates/pgflow-worker/ (next to this file).
# Pgflow version is pinned to whatever the supabase worktree's ControlPlane
# function uses (supabase/functions/pgflow/deno.json), falling back to 0.14.1.
scaffold_pgflow_worker() {
  local invoking_wt="$1"
  local supabase_wt="$2"
  local slug="$3"

  local kebab_slug
  kebab_slug=$(echo "$slug" | sed 's/\([A-Z]\)/-\1/g' | sed 's/^-//' | tr '[:upper:]' '[:lower:]')
  local worker_name="${kebab_slug}-worker"
  local source_file="$invoking_wt/supabase/flows/${kebab_slug}.ts"
  local worker_dir="$invoking_wt/supabase/functions/$worker_name"
  local helpers_dir
  helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local template_dir="$helpers_dir/templates/pgflow-worker"
  local pgflow_deno="$supabase_wt/supabase/functions/pgflow/deno.json"

  if [ -d "$worker_dir" ]; then
    return 0
  fi
  if [ ! -f "$source_file" ]; then
    echo "    (warning: $source_file missing — skipping worker scaffold)"
    return 0
  fi
  if [ ! -d "$template_dir" ]; then
    echo "    (warning: $template_dir missing — skipping worker scaffold)"
    return 0
  fi

  local flow_export
  flow_export=$(grep -oE 'export const [A-Z][A-Za-z0-9_]* = new Flow' "$source_file" \
    | head -n1 | awk '{print $3}')
  if [ -z "$flow_export" ]; then
    flow_export="$(echo "$slug" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    echo "    (note: no 'export const ... = new Flow' found in $(basename "$source_file"); falling back to $flow_export)"
  fi

  local pgflow_version=""
  if [ -f "$pgflow_deno" ]; then
    pgflow_version=$(grep -oE '@pgflow/edge-worker@[^"/]+' "$pgflow_deno" | head -n1 | sed 's|.*@||')
  fi
  [ -z "$pgflow_version" ] && pgflow_version="0.14.1"

  mkdir -p "$worker_dir"
  sed \
    -e "s|__FLOW_EXPORT__|${flow_export}|g" \
    -e "s|__KEBAB_SLUG__|${kebab_slug}|g" \
    "$template_dir/index.ts" > "$worker_dir/index.ts"
  sed \
    -e "s|__PGFLOW_VERSION__|${pgflow_version}|g" \
    "$template_dir/deno.json" > "$worker_dir/deno.json"
  echo "    Created worker scaffold: supabase/functions/${worker_name}/ (pgflow@${pgflow_version})"
}
