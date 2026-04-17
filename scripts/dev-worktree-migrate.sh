#!/usr/bin/env bash
set -euo pipefail

# Migration hub orchestrator for multi-worktree Supabase development.
# The "supabase" worktree serves as the single source of truth for migrations:
# - Real files from origin/main (the canonical set)
# - Symlinks from feature worktrees (their new migrations)
# All migration operations run from the supabase worktree.
#
# Subcommands:
#   link <wt_path>    Symlink a worktree's new migrations into the hub and apply
#   unlink <wt_path>  Remove a worktree's symlinks and refresh the hub
#   apply             Re-link current worktree's migrations and apply (for mid-work use)
#   find-supabase-wt  Print the supabase worktree path (for use by other scripts)

# --- Colors ---
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ────────────────────────────────────────────────────────────

find_supabase_wt() {
  local wt_path=""
  wt_path=$(git worktree list --porcelain | awk '/^worktree .*\/supabase$/ { print substr($0, 10) }')
  if [ -z "$wt_path" ]; then
    echo "Error: Supabase worktree not found. Run: dev sb up" >&2
    return 1
  fi
  echo "$wt_path"
}

update_supabase_wt() {
  local supabase_wt="$1"
  echo "Updating supabase worktree to origin/main..."
  git fetch origin
  (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
}

find_new_migrations() {
  local wt_path="$1"
  local supabase_wt="$2"
  # Compare the worktree's migration dirs against the supabase wt.
  # A migration needs symlinking if it exists in the worktree but is neither:
  # - a real (non-symlink) file in the supabase wt (from origin/main), nor
  # - already correctly symlinked from this worktree.
  local dir basename_f
  for dir in app jobs; do
    local wt_dir="$wt_path/supabase/migrations/$dir"
    local sb_dir="$supabase_wt/supabase/migrations/$dir"
    [ -d "$wt_dir" ] || continue
    for f in "$wt_dir"/*.sql; do
      [ -f "$f" ] || continue
      basename_f="$(basename "$f")"
      # Skip if it exists as a real (non-symlink) file in the supabase wt — it's from origin/main
      if [ -f "$sb_dir/$basename_f" ] && [ ! -L "$sb_dir/$basename_f" ]; then
        continue
      fi
      # Skip if already correctly symlinked from this worktree
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
  # List all real (non-symlink) .sql files, extract timestamp prefix, get the highest.
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
    return 0 # No origin migrations — nothing to check against
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

  # Build the diagnostic: show context around the conflict
  # Collect all origin migration basenames sorted by timestamp
  local origin_migrations=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    origin_migrations+=("$f")
  done < <(find "$supabase_wt/supabase/migrations" -name "*.sql" ! -type l -exec basename {} \; 2>/dev/null | sort)

  # Find the earliest outdated timestamp to show context
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

  # Show the last few origin migrations before the conflict point
  local context_shown=0
  for m in "${origin_migrations[@]}"; do
    local m_ts="${m%%_*}"
    if [ "$m_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      # Only show the last 2 before the conflict
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
      # This is an origin migration newer than the outdated ones
      printf "  ${GREEN}- %s  (origin/main)${RESET}\n" "$m"
    fi
  done

  # Show the outdated worktree migrations
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

    # Check for collision with a different worktree's symlink
    if [ -L "$link_path" ]; then
      local existing_target
      existing_target="$(realpath "$link_path" 2>/dev/null || readlink "$link_path")"
      if [ "$existing_target" != "$target_path" ]; then
        echo "Error: $basename_f already symlinked from a different worktree:" >&2
        echo "  Existing: $existing_target" >&2
        echo "  New:      $target_path" >&2
        return 1
      fi
      continue # Already correctly symlinked
    fi

    ln -s "$target_path" "$link_path"
    count=$((count + 1))
  done <<< "$new_files"

  if [ "$count" -gt 0 ]; then
    echo "Symlinked $count migration(s) into the migration hub"
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
    echo "Removed $count symlink(s) from the migration hub"
  fi
}

clean_stale_symlinks() {
  # Remove symlinks from a specific worktree whose targets no longer exist (file deleted/renamed).
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
    echo "Removed $count stale symlink(s) from the migration hub"
  fi
}

clean_all_stale_symlinks() {
  # Remove all broken symlinks from the hub (targets deleted, renamed, or worktree removed).
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
    echo "Removed $count stale symlink(s) from the migration hub"
  else
    echo "No stale symlinks found"
  fi
}

apply_migrations() {
  local supabase_wt="$1"
  echo "Applying migrations from supabase worktree..."
  if [ -x "$supabase_wt/scripts/db-migrate-local.sh" ]; then
    (cd "$supabase_wt" && ./scripts/db-migrate-local.sh)
  else
    (cd "$supabase_wt" && supabase migration up --local)
  fi
}

supabase_is_running() {
  supabase status --output json >/dev/null 2>&1
}

# ── Subcommands ────────────────────────────────────────────────────────

cmd_link() {
  local wt_path="$1"
  local wt_name
  wt_name="$(basename "$wt_path")"

  local supabase_wt
  supabase_wt="$(find_supabase_wt)"

  update_supabase_wt "$supabase_wt"
  apply_migrations "$supabase_wt"

  local new_files
  new_files="$(find_new_migrations "$wt_path" "$supabase_wt")"
  if [ -z "$new_files" ]; then
    echo "No new migrations in $wt_name"
    return 0
  fi

  echo "Found new migrations in $wt_name:"
  echo "$new_files" | sed 's/^/  /'

  local latest_ts
  latest_ts="$(get_latest_origin_timestamp "$supabase_wt")"
  check_timestamps "$wt_name" "$new_files" "$latest_ts" "$supabase_wt"

  symlink_migrations "$wt_path" "$new_files" "$supabase_wt"
  apply_migrations "$supabase_wt"
}

cmd_unlink() {
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

  # Repair migration history — remove versions from the tracking table so
  # `supabase migration up` doesn't fail on missing files.
  # Uses psql via Docker as supabase_admin because the postgres role lacks
  # write access to supabase_migrations.schema_migrations.
  if [ ${#versions[@]} -gt 0 ]; then
    local project_id
    project_id="$(sed -n 's/^project_id = "\(.*\)"/\1/p' "$supabase_wt/supabase/config.toml")"
    local db_container="supabase_db_${project_id}"

    local version_list
    version_list=$(printf "'%s'," "${versions[@]}")
    version_list="${version_list%,}"  # trim trailing comma

    echo "Repairing migration history: ${versions[*]} => reverted"
    docker exec -e PGPASSWORD=postgres "$db_container" \
      psql -U supabase_admin -d postgres -c \
      "DELETE FROM supabase_migrations.schema_migrations WHERE version IN ($version_list);" \
      2>/dev/null || echo "  (warning: migration repair failed — continuing)"
  fi

  update_supabase_wt "$supabase_wt"

  if supabase_is_running; then
    apply_migrations "$supabase_wt"
  fi
}

cmd_apply() {
  local current_wt
  current_wt="$(git rev-parse --show-toplevel)"

  local supabase_wt
  supabase_wt="$(find_supabase_wt)"

  update_supabase_wt "$supabase_wt"
  apply_migrations "$supabase_wt"

  # If we're in a feature worktree (not the supabase wt), link its migrations
  if [ "$current_wt" != "$supabase_wt" ]; then
    local wt_name
    wt_name="$(basename "$current_wt")"

    # Clean stale symlinks (deleted/renamed files) — leave valid ones in place
    clean_stale_symlinks "$current_wt" "$supabase_wt"

    local new_files
    new_files="$(find_new_migrations "$current_wt" "$supabase_wt")"
    if [ -z "$new_files" ]; then
      echo "No new migrations in $wt_name"
      return 0
    fi

    echo "Found new migrations in $wt_name:"
    echo "$new_files" | sed 's/^/  /'

    local latest_ts
    latest_ts="$(get_latest_origin_timestamp "$supabase_wt")"
    check_timestamps "$wt_name" "$new_files" "$latest_ts" "$supabase_wt"

    symlink_migrations "$current_wt" "$new_files" "$supabase_wt"
    apply_migrations "$supabase_wt"
  fi
}

cmd_find_supabase_wt() {
  find_supabase_wt
}

# ── Dispatch ───────────────────────────────────────────────────────────

case "${1:-}" in
  link)
    if [ -z "${2:-}" ]; then
      echo "Usage: dev-worktree-migrate.sh link <worktree-path>" >&2
      exit 1
    fi
    cmd_link "$2"
    ;;
  unlink)
    if [ -z "${2:-}" ]; then
      echo "Usage: dev-worktree-migrate.sh unlink <worktree-path>" >&2
      exit 1
    fi
    cmd_unlink "$2"
    ;;
  apply)
    cmd_apply
    ;;
  clean-all)
    if [ -z "${2:-}" ]; then
      echo "Usage: dev-worktree-migrate.sh clean-all <supabase-wt-path>" >&2
      exit 1
    fi
    clean_all_stale_symlinks "$2"
    ;;
  find-supabase-wt)
    cmd_find_supabase_wt
    ;;
  *)
    echo "Usage: dev-worktree-migrate.sh <link|unlink|apply|clean-all|find-supabase-wt> [args]" >&2
    echo "" >&2
    echo "Subcommands:" >&2
    echo "  link <wt_path>       Symlink a worktree's new migrations and apply" >&2
    echo "  unlink <wt_path>     Remove a worktree's symlinks and refresh" >&2
    echo "  apply                Re-link current worktree's migrations and apply" >&2
    echo "  clean-all <sb_wt>    Remove all stale symlinks from the hub" >&2
    echo "  find-supabase-wt     Print the supabase worktree path" >&2
    exit 1
    ;;
esac
