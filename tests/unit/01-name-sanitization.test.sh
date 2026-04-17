#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: name sanitization${RESET}\n"

header "name sanitization"

sanitize() { echo "$1" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-'; }

assert_eq "slashes become dashes" "feat-new-chat" "$(sanitize "feat/new-chat")"
assert_eq "nested slashes" "feat-team-new-chat" "$(sanitize "feat/team/new-chat")"
assert_eq "plain name unchanged" "my-branch" "$(sanitize "my-branch")"
assert_eq "special chars stripped" "featbranch" "$(sanitize "feat@branch!")"
assert_eq "dots preserved" "v1.2.3" "$(sanitize "v1.2.3")"
assert_eq "underscores preserved" "feat_thing" "$(sanitize "feat_thing")"

print_results
