#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#3 — dev sb status${RESET}\n"

header "shows status when running"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-status.sh" 2>&1) || true

# supabase status output contains service URLs
assert_contains "shows supabase info" "54421" "$OUTPUT"

print_results
