#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#4 — dev wt env (pick up Supabase keys)${RESET}\n"

header "env injection with real Supabase"
cd "$WORKTREE_BASE/feat-alpha"

export SUPABASE_STATUS_DIR="$WORKTREE_BASE/supabase"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-env.sh" 2>&1) || true
unset SUPABASE_STATUS_DIR

assert_contains "injecting message" "Injecting Supabase env vars" "$OUTPUT"

ENV_LOCAL=$(cat "$WORKTREE_BASE/feat-alpha/.env.local")

header "supabase vars populated"
assert_contains "SUPABASE_URL present" "NEXT_PUBLIC_SUPABASE_URL=" "$ENV_LOCAL"
assert_contains "ANON_KEY present" "NEXT_PUBLIC_SUPABASE_ANON_KEY=" "$ENV_LOCAL"

SUPABASE_URL=$(grep "^NEXT_PUBLIC_SUPABASE_URL=" "$WORKTREE_BASE/feat-alpha/.env.local" | cut -d= -f2-)
assert_contains "URL uses localhost" "localhost" "$SUPABASE_URL"
assert_contains "URL has host" "localhost" "$SUPABASE_URL"

header "COPYMIND_API_HOST"
assert_contains "API HOST set" "COPYMIND_API_HOST=" "$ENV_LOCAL"

API_HOST=$(grep "^COPYMIND_API_HOST=" "$WORKTREE_BASE/feat-alpha/.env.local" | cut -d= -f2-)
assert_contains "uses docker internal host" "host.docker.internal" "$API_HOST"
assert_contains "uses docker internal" "host.docker.internal" "$API_HOST"

header "supabase worktree skips COPYMIND_API_HOST"
cd "$WORKTREE_BASE/supabase"

export SUPABASE_STATUS_DIR="$WORKTREE_BASE/supabase"
SUPABASE_OUTPUT=$("$SCRIPTS_DIR/dev-worktree-env.sh" 2>&1) || true
unset SUPABASE_STATUS_DIR

assert_contains "skip message printed" "Skipping COPYMIND_API_HOST (supabase worktree has no app port)" "$SUPABASE_OUTPUT"
assert_not_contains "no port-registry warning" "Could not determine COPYMIND_API_HOST port" "$SUPABASE_OUTPUT"

SUPABASE_ENV_LOCAL=$(cat "$WORKTREE_BASE/supabase/.env.local" 2>/dev/null || echo "")
assert_not_contains "COPYMIND_API_HOST not written" "COPYMIND_API_HOST=" "$SUPABASE_ENV_LOCAL"

print_results
