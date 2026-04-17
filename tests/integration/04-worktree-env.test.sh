#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#4 — dev wt env (pick up Supabase keys)${RESET}\n"

header "env injection with real Supabase"
cd "$TEST_DIR/feat-alpha"

export SUPABASE_STATUS_DIR="$TEST_DIR/supabase"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-env.sh" 2>&1) || true
unset SUPABASE_STATUS_DIR

assert_contains "injecting message" "Injecting Supabase env vars" "$OUTPUT"

ENV_LOCAL=$(cat "$TEST_DIR/feat-alpha/.env.local")

header "supabase vars populated"
assert_contains "SUPABASE_URL present" "NEXT_PUBLIC_SUPABASE_URL=" "$ENV_LOCAL"
assert_contains "ANON_KEY present" "NEXT_PUBLIC_SUPABASE_ANON_KEY=" "$ENV_LOCAL"

SUPABASE_URL=$(grep "^NEXT_PUBLIC_SUPABASE_URL=" "$TEST_DIR/feat-alpha/.env.local" | cut -d= -f2-)
assert_contains "URL uses localhost" "localhost" "$SUPABASE_URL"
assert_contains "URL has correct port" "54421" "$SUPABASE_URL"

header "COPYMIND_API_HOST"
assert_contains "API HOST set" "COPYMIND_API_HOST=" "$ENV_LOCAL"

API_HOST=$(grep "^COPYMIND_API_HOST=" "$TEST_DIR/feat-alpha/.env.local" | cut -d= -f2-)
assert_contains "uses docker internal host" "host.docker.internal" "$API_HOST"
assert_contains "uses port 13001" "13001" "$API_HOST"

print_results
