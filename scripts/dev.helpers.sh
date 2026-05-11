#!/usr/bin/env bash
# Side-effect-free utilities shared across dev-* scripts. Source this,
# don't execute. Anything sourced here must NOT exit/error at source time
# so that consumers without supabase/git/docker can still load it.

# --- Colors ---
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# Abort unless invoked from a worktree of a bare-cloned repo. The whole
# `dev wt`/`dev sb` toolchain assumes that layout (worktrees-as-siblings
# of the bare .git dir), so the check is shared across worktree + supabase
# scripts.
require_bare_repo() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir)"
  if ! git -C "$git_common_dir" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
    echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
    exit 1
  fi
}

# `git clone --bare` skips writing a remote.origin.fetch refspec, which
# breaks `git fetch origin` for remote branches. Set the standard refspec
# if missing. Idempotent.
ensure_fetch_refspec() {
  if ! git config --get remote.origin.fetch &>/dev/null; then
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  fi
}

# Update or append a key=value pair in a file. Idempotent. The sed
# delimiter is `|` so URL values with `/` and `:` need no escaping; if
# you need to upsert a value containing `|`, switch the delimiter.
upsert_env() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed "s|^${key}=.*|${key}=${val}|" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    # Ensure file ends with a newline before appending to avoid concatenation
    [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo "" >>"$file"
    echo "${key}=${val}" >>"$file"
  fi
}

# Update or insert a key=value pair in a flat .env file, keeping the file
# sorted alphabetically by key (byte order, locale-independent). Strips any
# existing line with the same key before inserting. Values with `=`, `/`,
# `:`, etc. are written verbatim.
upsert_env_sorted() {
  local file="$1" key="$2" val="$3"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" 2>/dev/null > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  LC_ALL=C sort "$tmp" -o "$file"
  rm -f "$tmp"
}

# Delete the `^<key>=` line from a flat .env file. No-op if absent.
remove_env() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    grep -v "^${key}=" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
}

# Read y/n from stdin. Returns 0 for yes, 1 for no.
# Usage: confirm "Proceed?" [y|n]   (second arg is the default; defaults to n)
confirm() {
  local prompt="$1" default="${2:-n}" reply
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "$prompt $hint " reply
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Silent prompt; reads a value without echoing into the named variable.
# Usage: prompt_secret target_var "Prompt: "
prompt_secret() {
  local __target="$1" __prompt="$2" __value
  read -r -s -p "$__prompt" __value
  echo
  printf -v "$__target" '%s' "$__value"
}

# Verify the Vercel CLI is installed, the user logged in, and the given
# repo root is linked. Errors with a clear hint per failure mode.
vercel_check_auth() {
  local repo_root="$1"
  if ! command -v vercel >/dev/null 2>&1; then
    echo "Error: vercel CLI not found. Install with: npm i -g vercel" >&2
    exit 1
  fi
  if ! vercel whoami >/dev/null 2>&1; then
    echo "Error: not logged in to Vercel. Run: vercel login" >&2
    exit 1
  fi
  if [ ! -f "$repo_root/.vercel/project.json" ]; then
    echo "Error: Vercel project not linked. Run: vercel link" >&2
    echo "       (from $repo_root)" >&2
    exit 1
  fi
}

# Returns 0 if <name> is set in <env>, 1 otherwise. Uses the Vercel
# REST API directly instead of `vercel env ls --json`, because the
# latter (a) isn't supported on every CLI version (some reject --json
# entirely) and (b) filters out encrypted/sensitive entries on others.
# The API is the only reliable source of truth.
vercel_var_exists() {
  local env="$1" name="$2"
  # Resolve script dir relative to this helpers file (dev.helpers.sh
  # is sourced from sibling scripts; ${BASH_SOURCE[0]} points here).
  local helpers_dir
  helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  node "$helpers_dir/dev-env.helpers.mjs" exists "$name" "$env" 2>/dev/null
}

# Generic retry wrapper for flaky operations. Backoff grows linearly:
# 15s, 20s, 25s, 30s ... (10 + attempt * 5).
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
