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
