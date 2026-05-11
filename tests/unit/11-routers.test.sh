#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}02 — Router dispatch${RESET}\n"

# ── Discovery ────────────────────────────────────────────────────────
#
# Filename convention:
#   dev.sh                         → top-level router
#   dev-<ns>.sh                    → namespace router (when children exist),
#                                    also a leaf of dev.sh
#   dev-<ns>-<leaf>.sh             → leaf of dev-<ns>.sh
#   dev-<leaf>.sh   (no children)  → leaf of dev.sh
#   *.helpers.sh                   → sourced library, skipped
#
# Adding a new dev-*.sh therefore requires wiring it into the matching
# router — this test catches the omission without needing per-script
# assertions.

ALL_SCRIPTS=()
for f in "$SCRIPTS_DIR"/dev-*.sh; do
  base="$(basename "$f" .sh)"
  [[ "$base" == *.helpers ]] && continue
  ALL_SCRIPTS+=("$base")
done

has_children() {
  local name="$1" f base
  for f in "$SCRIPTS_DIR"/${name}-*.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .sh)"
    [[ "$base" == *.helpers ]] && continue
    return 0
  done
  return 1
}

ROUTERS=("dev")
for base in "${ALL_SCRIPTS[@]}"; do
  has_children "$base" && ROUTERS+=("$base")
done

# Verify a router's case statement contains a clause matching <leaf>
# (handles aliases like `s|session)` or `remove|rm)`).
assert_dispatches() {
  local label="$1" router="$2" leaf="$3"
  if [ ! -f "$router" ]; then
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — parent router missing: %s\n" "$label" "$(basename "$router")"
    return
  fi
  if grep -qE "^[[:space:]]+([a-zA-Z_-]+\|)*${leaf}(\|[a-zA-Z_-]+)*\)" "$router"; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — '%s' not dispatched in %s\n" "$label" "$leaf" "$(basename "$router")"
  fi
}

# ── Every dev-*.sh must be dispatched by its parent router ──────────

header "every dev-*.sh is dispatched by its router"
for base in "${ALL_SCRIPTS[@]}"; do
  name="${base#dev-}"
  if [[ "$name" == *-* ]]; then
    namespace="${name%%-*}"
    leaf="${name#*-}"
    parent="dev-${namespace}"
  else
    leaf="$name"
    parent="dev"
  fi
  assert_dispatches "${base}.sh ← ${parent}.sh" "$SCRIPTS_DIR/${parent}.sh" "$leaf"
done

# ── Every router exits 1 with usage on no args / unknown subcommand ─

header "routers — no args"
for r in "${ROUTERS[@]}"; do
  EXIT_CODE=0
  OUTPUT=$(bash "$SCRIPTS_DIR/${r}.sh" 2>&1) || EXIT_CODE=$?
  assert_exit_code "${r}.sh exits with 1" "1" "$EXIT_CODE"
  assert_contains "${r}.sh shows Usage:" "Usage:" "$OUTPUT"
done

header "routers — unknown subcommand"
for r in "${ROUTERS[@]}"; do
  EXIT_CODE=0
  OUTPUT=$(bash "$SCRIPTS_DIR/${r}.sh" __nonexistent_xyz__ 2>&1) || EXIT_CODE=$?
  assert_exit_code "${r}.sh exits with 1" "1" "$EXIT_CODE"
done

print_results
