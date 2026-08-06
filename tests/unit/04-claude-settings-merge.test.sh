#!/usr/bin/env bash
# claude/merge-settings.sh must install the status line and hooks into somebody
# else's Claude config without taking anything away from it.
#
# The load-bearing test here is `assert_no_loss`, which is a property rather than
# a list: for every scalar leaf in the original config, outside the two keys we
# own, the merged result must hold the same value at the same path. That covers
# settings nobody has thought of yet, which a key-by-key check cannot.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: Claude settings merge${RESET}\n"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MERGE="$ROOT/claude/merge-settings.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The real shared file, so these tests fail if it ever grows a third key.
SHARED="$ROOT/claude/settings.json"

merge() { "$MERGE" "$1" "$SHARED"; }

# Paths in $1 whose value is missing or changed in $2, ignoring the two keys the
# merge is allowed to own.
#
# The path is bound to $p rather than left as `.`: inside the select, the pipe
# has already rebound `.` to the document being searched, so getpath(.) asks for
# the document as a path and jq errors out. That failure is silent in the worst
# possible way -- the command substitution captures nothing, empty compares equal
# to empty, and the assertion passes while checking nothing at all. Hence the
# self-check below.
lost_paths() {
  jq -rn --slurpfile before "$1" --slurpfile after "$2" '
    [ $before[0]
      | paths(scalars)
      | select(.[0] != "statusLine" and .[0] != "hooks") ] as $paths
    | [ $paths[] as $p
        | select(($after[0] | getpath($p)) != ($before[0] | getpath($p)))
        | $p | map(tostring) | join(".") ]
    | join(", ")'
}

assert_no_loss() { # <label> <before.json> <after.json>
  assert_eq "$1" "" "$(lost_paths "$2" "$3")"
}

# --- does the detector detect? ----------------------------------------------
# Everything below leans on lost_paths reporting an empty string, which is also
# what it reports when it is broken. So first make it prove it can see a loss.
header "the loss detector works"

printf '%s' '{"keep":"a","drop":"b","nested":{"gone":1,"stays":2}}' > "$TMP/before.json"
printf '%s' '{"keep":"a","nested":{"stays":2}}'                     > "$TMP/after.json"
assert_eq "a dropped key is reported" \
  "drop, nested.gone" "$(lost_paths "$TMP/before.json" "$TMP/after.json")"

printf '%s' '{"keep":"a","changed":"old"}' > "$TMP/before.json"
printf '%s' '{"keep":"a","changed":"new"}' > "$TMP/after.json"
assert_eq "a changed value is reported" \
  "changed" "$(lost_paths "$TMP/before.json" "$TMP/after.json")"

printf '%s' '{"keep":"a","statusLine":{"command":"old"},"hooks":{"Stop":[]}}' > "$TMP/before.json"
printf '%s' '{"keep":"a","statusLine":{"command":"new"}}'                     > "$TMP/after.json"
assert_eq "changes to the two keys we own are not reported" \
  "" "$(lost_paths "$TMP/before.json" "$TMP/after.json")"

# --- a config with something of everything in it ----------------------------
header "nothing is lost from a populated config"

cat > "$TMP/full.json" <<'EOF'
{
  "editorMode": "emacs",
  "model": "sonnet",
  "tui": "inline",
  "agentPushNotifEnabled": false,
  "skipAutoPermissionPrompt": false,
  "skipDangerousModePermissionPrompt": false,
  "enabledPlugins": { "their-plugin@somewhere": true },
  "extraKnownMarketplaces": { "theirs": { "source": { "source": "github", "repo": "them/plugins" } } },
  "permissions": { "allow": ["Bash(their-tool:*)"], "deny": ["Read(./secrets/**)"], "defaultMode": "default" },
  "env": { "THEIR_SETTING": "kept-verbatim", "NESTED_UNUSED": "keep me" },
  "outputStyle": "explanatory",
  "someFutureKey": { "deeply": { "nested": [1, 2, "three"] } },
  "statusLine": { "type": "command", "command": "~/bin/their-statusline.sh" },
  "hooks": {
    "PostToolUse": [ { "matcher": "Edit", "hooks": [ { "type": "command", "command": "~/bin/prettier.sh" } ] } ],
    "SubagentStop": [ { "hooks": [ { "type": "command", "command": "~/bin/notify.sh" } ] } ]
  }
}
EOF

merge "$TMP/full.json" > "$TMP/full.out"
assert_no_loss "every unrelated setting survives" "$TMP/full.json" "$TMP/full.out"

# A real credential is what this protects, but the fixture must not be one: a
# credential-shaped string committed here would trip 03-no-secrets, and rightly.
assert_eq "their env value is byte-identical" \
  "kept-verbatim" "$(jq -r '.env.THEIR_SETTING' "$TMP/full.out")"
assert_eq "their permission mode is not touched" \
  "default" "$(jq -r '.permissions.defaultMode' "$TMP/full.out")"
assert_eq "their allow list is not touched" \
  "Bash(their-tool:*)" "$(jq -r '.permissions.allow | join(",")' "$TMP/full.out")"
assert_eq "a key we have never heard of survives" \
  "1,2,three" "$(jq -r '.someFutureKey.deeply.nested | map(tostring) | join(",")' "$TMP/full.out")"
assert_eq "no key disappears" \
  "$(jq -r 'keys | sort | join(" ")' "$TMP/full.json")" \
  "$(jq -r 'keys | sort | join(" ")' "$TMP/full.out")"

# --- the two keys we do own --------------------------------------------------
header "the shared keys are installed"

assert_eq "our status line replaces theirs" \
  "$(jq -r '.statusLine.command' "$SHARED")" \
  "$(jq -r '.statusLine.command' "$TMP/full.out")"

assert_contains "our hook is added to an event they already use" \
  "monitor-hook.sh" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[].command] | join(" ")' "$TMP/full.out")"
assert_contains "their hook on that same event is kept" \
  "prettier.sh" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[].command] | join(" ")' "$TMP/full.out")"
assert_eq "their matcher is preserved verbatim" \
  "Edit" "$(jq -r '.hooks.PostToolUse[0].matcher' "$TMP/full.out")"
assert_eq "an event we do not define is left exactly as it was" \
  "~/bin/notify.sh" \
  "$(jq -r '[.hooks.SubagentStop[].hooks[].command] | join(" ")' "$TMP/full.out")"

for ev in $(jq -r '.hooks | keys[]' "$SHARED"); do
  assert_eq "our hook is present on $ev" "1" \
    "$(jq -r --arg e "$ev" '[.hooks[$e][].hooks[].command | select(test("monitor-hook"))] | length' "$TMP/full.out")"
done

# --- running it more than once ----------------------------------------------
header "re-running converges"

merge "$TMP/full.out" > "$TMP/twice.out"
assert_eq "a second merge changes nothing" \
  "$(jq -S . "$TMP/full.out")" "$(jq -S . "$TMP/twice.out")"
merge "$TMP/twice.out" > "$TMP/thrice.out"
assert_eq "a third merge changes nothing" \
  "$(jq -S . "$TMP/twice.out")" "$(jq -S . "$TMP/thrice.out")"
assert_eq "our hook is still listed once, not three times" "1" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[].command | select(test("monitor-hook"))] | length' "$TMP/thrice.out")"
assert_eq "and theirs is still there after three runs" "1" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[].command | select(test("prettier"))] | length' "$TMP/thrice.out")"

# --- the empty and near-empty cases -----------------------------------------
header "a config that barely exists"

echo '{}' > "$TMP/empty.json"
merge "$TMP/empty.json" > "$TMP/empty.out"
assert_eq "an empty config gains exactly the shared keys" \
  "hooks statusLine" "$(jq -r 'keys | sort | join(" ")' "$TMP/empty.out")"
assert_eq "and inherits no preferences from this repo" "null" \
  "$(jq -r '.model // "null"' "$TMP/empty.out")"

echo '{"hooks":{}}' > "$TMP/emptyhooks.json"
merge "$TMP/emptyhooks.json" > "$TMP/emptyhooks.out"
assert_eq "an empty hooks object is filled in, not tripped over" \
  "$(jq -r '.hooks | keys | sort | join(" ")' "$SHARED")" \
  "$(jq -r '.hooks | keys | sort | join(" ")' "$TMP/emptyhooks.out")"

echo '{"env":{"ONLY":"thing"}}' > "$TMP/envonly.json"
merge "$TMP/envonly.json" > "$TMP/envonly.out"
assert_no_loss "a config that is only an env block keeps it" \
  "$TMP/envonly.json" "$TMP/envonly.out"

# --- refusals ----------------------------------------------------------------
header "it refuses rather than damages"

echo '{"statusLine":{"command":"x"},"env":{"LEAK":"secret"}}' > "$TMP/badshared.json"
"$MERGE" "$TMP/full.json" "$TMP/badshared.json" >"$TMP/refused.out" 2>/dev/null && rc=0 || rc=$?
assert_eq "a shared file with an env block is refused" "2" "$rc"
assert_eq "and nothing is written on refusal" "" "$(cat "$TMP/refused.out")"

printf 'not json at all' > "$TMP/broken.json"
"$MERGE" "$TMP/broken.json" "$SHARED" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "invalid live JSON is refused" "1" "$rc"
"$MERGE" "$TMP/missing-$$.json" "$SHARED" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "an unreadable file is refused" "1" "$rc"
"$MERGE" "$TMP/full.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "wrong argument count is refused" "1" "$rc"

# --- the real config on this machine, if there is one ------------------------
header "the config on this machine"

if [ -r "$HOME/.claude/settings.json" ] && jq empty "$HOME/.claude/settings.json" 2>/dev/null; then
  merge "$HOME/.claude/settings.json" > "$TMP/real.out"
  assert_no_loss "merging this machine's real config loses nothing" \
    "$HOME/.claude/settings.json" "$TMP/real.out"
else
  echo "  (skipped: no readable ~/.claude/settings.json)"
fi

print_results
