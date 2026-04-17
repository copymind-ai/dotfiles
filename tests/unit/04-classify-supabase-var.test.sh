#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: classify_supabase_var${RESET}\n"

eval "$(sed -n '/^classify_supabase_var()/,/^}/p' "$SCRIPTS_DIR/dev-worktree-env.sh")"

header "classify_supabase_var"

assert_eq "SUPABASE_URL → API_URL" "API_URL" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_URL")"
assert_eq "ANON_KEY" "ANON_KEY" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")"
assert_eq "SERVICE_ROLE_KEY" "SERVICE_ROLE_KEY" "$(classify_supabase_var "SUPABASE_SERVICE_ROLE_KEY")"
assert_eq "DB_URL" "DB_URL" "$(classify_supabase_var "DATABASE_URL")"
assert_eq "JWT_SECRET" "JWT_SECRET" "$(classify_supabase_var "JWT_SECRET")"
assert_eq "unmapped → empty" "" "$(classify_supabase_var "SOME_OTHER_VAR")"

print_results
