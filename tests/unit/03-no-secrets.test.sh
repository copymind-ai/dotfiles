#!/usr/bin/env bash
# Nothing committed here should carry a credential.
#
# This exists because it nearly happened: ~/.claude/settings.json holds a
# Supabase token in its env block, and bringing Claude's config under dotfiles
# meant copying that file into a repo with a GitHub remote. claude/settings.json
# is generated without env for that reason, and this is what keeps it that way.
#
# Two checks, because either alone misses the other's case: known token prefixes
# catch a credential pasted anywhere, and secret-shaped JSON keys catch one whose
# format we have never seen.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: no secrets in tracked files${RESET}\n"

header "no secrets in tracked files"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Anchored on a non-word character so a prefix sitting inside an ordinary word
# does not count -- "task-specific" contains "sk-", which is not an API key.
PREFIXES='(^|[^[:alnum:]_-])(sk-ant-|sbp_|sbs_|ghp_|gho_|ghs_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'

# A JSON key that names a credential, with a non-empty string value. This is the
# one that would have caught SUPABASE_ACCESS_TOKEN whatever its value looked like.
SECRET_KEYS='"[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)"[[:space:]]*:[[:space:]]*"[^"]+"'

# Tracked files and new ones that are not ignored. The untracked half matters
# most: a secret is at its most dangerous in the moment before it is first
# committed, which is exactly when `git ls-files` alone cannot see it.
#
# The whole thing runs inside $ROOT. git lists paths relative to the repo, so a
# grep started anywhere else opens none of them, finds nothing, and reports a
# clean bill of health for a repo it never read -- which is indistinguishable
# from a real pass. The self-check below is what keeps that honest.
scan() { # <regex> -> matching "file:line: text", excluding this test itself
  ( cd "$ROOT" 2>/dev/null || exit 0
    { git ls-files -z 2>/dev/null
      git ls-files -z --others --exclude-standard 2>/dev/null
    } | xargs -0 grep -nEI "$1" 2>/dev/null |
      grep -v '^tests/unit/03-no-secrets.test.sh:' ) || true
}

# --- does the scanner read anything? -----------------------------------------
# Plant a credential-shaped string in the repo and require the scan to find it,
# so "no matches" cannot quietly mean "no files were opened".
header "the scanner reads the repo"

CANARY="$ROOT/.secret-scan-canary.tmp"
trap 'rm -f "$CANARY"' EXIT
printf 'ghp_%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" > "$CANARY"
assert_contains "a planted token in an untracked file is found" \
  ".secret-scan-canary.tmp" "$(scan "$PREFIXES")"
rm -f "$CANARY"
assert_eq "and the repo is clean once it is gone" "" "$(scan "$PREFIXES")"

hits=$(scan "$PREFIXES")
assert_eq "no credential-shaped tokens in tracked files" "" "$hits"

hits=$(scan "$SECRET_KEYS")
assert_eq "no secret-named JSON keys with values" "" "$hits"

# The specific shape that started this: no tracked Claude settings file may carry
# an env block at all, even an empty one, so nothing can accrete into it.
for f in "$ROOT"/claude/settings*.json; do
  [ -f "$f" ] || continue
  assert_eq "$(basename "$f") declares no env block" \
    "false" "$(jq -r 'has("env")' "$f")"
done

# Only the status line and the hooks are shared. Everything else in a Claude
# settings file belongs to whoever owns the laptop -- editor mode, model, plugins,
# and above all the permission posture, which decides how much Claude does
# without asking. Enforcing the whole key set rather than blocklisting the
# dangerous ones means a future addition has to be a deliberate edit here too.
for f in "$ROOT"/claude/settings*.json; do
  [ -f "$f" ] || continue
  assert_eq "$(basename "$f") shares only statusLine and hooks" \
    "hooks statusLine" "$(jq -r 'keys | sort | join(" ")' "$f")"
done

print_results
