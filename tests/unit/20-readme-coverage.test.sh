#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: README command coverage${RESET}\n"

README="$DOTFILES_DIR/README.md"

# ── Discovery (mirrors 11-routers.test.sh) ──────────────────────────

ALL_SCRIPTS=()
for f in "$SCRIPTS_DIR"/dev-*.sh; do
  base="$(basename "$f" .sh)"
  [[ "$base" == *.helpers ]] && continue
  ALL_SCRIPTS+=("$base")
done

# Pull every alias from the case clause matching <leaf> in <router>.
# Example: clause `sb|supabase)` in dev.sh for leaf "supabase" → "sb supabase".
get_aliases() {
  local router="$1" leaf="$2"
  grep -E "^[[:space:]]+([a-zA-Z_-]+\|)*${leaf}(\|[a-zA-Z_-]+)*\)" "$router" \
    | head -1 \
    | sed -E 's/^[[:space:]]+//;s/\)[[:space:]]*$//' \
    | tr '|' ' '
}

# A command is "documented" if any of its alias forms appears in README
# inside backticks, optionally followed by argument text:
#   `dev sb up`              ✓
#   `dev sb up --force`      ✓
#   dev sb up                ✗ (no backticks)
readme_mentions() {
  local cmd="$1"
  grep -qE "\`${cmd}( [^\`]*)?\`" "$README"
}

header "every dev-*.sh command appears in README.md"
for base in "${ALL_SCRIPTS[@]}"; do
  name="${base#dev-}"
  if [[ "$name" == *-* ]]; then
    ns="${name%%-*}"
    leaf="${name#*-}"
    ns_aliases=($(get_aliases "$SCRIPTS_DIR/dev.sh" "$ns"))
    leaf_aliases=($(get_aliases "$SCRIPTS_DIR/dev-${ns}.sh" "$leaf"))
    forms=()
    for n in "${ns_aliases[@]}"; do
      for l in "${leaf_aliases[@]}"; do
        forms+=("dev $n $l")
      done
    done
  else
    leaf="$name"
    leaf_aliases=($(get_aliases "$SCRIPTS_DIR/dev.sh" "$leaf"))
    forms=()
    for l in "${leaf_aliases[@]}"; do
      forms+=("dev $l")
    done
  fi

  if [ ${#forms[@]} -eq 0 ]; then
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s.sh — no command forms derived (router wiring issue?)\n" "$base"
    continue
  fi

  matched=0
  for f in "${forms[@]}"; do
    if readme_mentions "$f"; then
      matched=1
      break
    fi
  done

  if [ "$matched" = "1" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s.sh\n" "$base"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s.sh — none of [%s] in README.md\n" "$base" "${forms[*]}"
  fi
done

print_results
