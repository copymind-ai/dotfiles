#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: CLI help coverage${RESET}\n"

# A "router" is a script that dispatches on $1 (`case "${1:-}" in …`) and
# documents its subcommands in a `*)` usage block. This test discovers every
# router and asserts:
#   (a) it prints a usage block (so every level of the CLI is self-describing),
#   (b) every subcommand it dispatches is mentioned in that block.
#
# New commands are covered automatically, the same way 21-readme-coverage works
# for the README: wire a subcommand into a router's `case` and it MUST also show
# up in the router's usage text, or this test fails. No per-command edits here.

# ── Discovery: every dev*.sh that dispatches on $1 ──────────────────
ROUTERS=()
for f in "$SCRIPTS_DIR"/dev.sh "$SCRIPTS_DIR"/dev-*.sh; do
  [[ "$f" == *.helpers.sh ]] && continue
  grep -qF 'case "${1:-}" in' "$f" && ROUTERS+=("$f")
done

# Dispatched subcommand clauses (alias groups like "remove|rm"), excluding `*)`.
router_subcommands() {
  awk '
    index($0, "case \"${1:-}\" in") { incase=1; next }
    incase && $0 ~ /^[[:space:]]*esac/ { incase=0 }
    !incase { next }
    $0 ~ /^[[:space:]]*\*\)/ { next }
    {
      s = $0; sub(/^[[:space:]]*/, "", s)
      if (s ~ /^[a-zA-Z][a-zA-Z0-9|_-]*\)/) { sub(/\).*/, "", s); print s }
    }
  ' "$1"
}

# A router prints its usage on any unrecognized subcommand.
router_usage() { bash "$1" __help_coverage_probe__ 2>&1 || true; }

# ── Assertions ──────────────────────────────────────────────────────

assert_eq "discovered ≥ 5 routers" "yes" "$([ "${#ROUTERS[@]}" -ge 5 ] && echo yes || echo no)"

header "every router prints a usage block"
for r in "${ROUTERS[@]}"; do
  assert_contains "$(basename "$r") prints 'Usage:'" "Usage:" "$(router_usage "$r")"
done

header "every dispatched subcommand is documented in its router"
for r in "${ROUTERS[@]}"; do
  usage="$(router_usage "$r")"
  base="$(basename "$r")"
  while IFS= read -r clause; do
    [ -n "$clause" ] || continue
    # Pass if ANY alias of the clause appears in the usage block.
    documented=0
    IFS='|' read -ra aliases <<<"$clause"
    for a in "${aliases[@]}"; do
      if printf '%s' "$usage" | grep -qw -- "$a"; then documented=1; break; fi
    done
    if [ "$documented" = 1 ]; then
      PASSED=$((PASSED + 1))
      printf "  ${GREEN}✓${RESET} %s → %s\n" "$base" "$clause"
    else
      FAILED=$((FAILED + 1))
      printf "  ${RED}✗${RESET} %s → '%s' dispatched but not in usage block\n" "$base" "$clause"
    fi
  done < <(router_subcommands "$r")
done

print_results
