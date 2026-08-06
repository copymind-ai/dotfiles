#!/usr/bin/env bash
# Merge the shared Claude Code settings into an existing config, without losing
# anything already in it.
#
#   merge-settings.sh <live.json> <shared.json>   -> merged JSON on stdout
#
# Only two keys are shared, statusLine and hooks, because those are what the tmux
# session monitor reads. Everything else in a Claude settings file belongs to
# whoever owns the laptop -- editor mode, model, plugins, the env block with its
# tokens, and the permission posture that decides how much Claude does without
# asking. This never writes a key it was not given.
#
# The two shared keys are applied differently on purpose:
#
#   statusLine  replaced. There is only one of it.
#   hooks       appended per event. Hook arrays live under one key per event, so
#               replacing the key would silently drop a colleague's own
#               PostToolUse formatter. Entries pointing at a command we are about
#               to add are dropped first, so running this repeatedly converges
#               instead of stacking duplicates.
#
# Exit codes: 0 merged, 1 bad usage or unreadable/invalid JSON, 2 the shared file
# carries an env block (which is how a secret would reach a teammate's machine --
# refused rather than merged).
set -uo pipefail

if [ $# -ne 2 ]; then
  printf 'usage: %s <live.json> <shared.json>\n' "$(basename "$0")" >&2
  exit 1
fi

live=$1
shared=$2

for f in "$live" "$shared"; do
  if [ ! -r "$f" ]; then
    printf '%s: cannot read %s\n' "$(basename "$0")" "$f" >&2
    exit 1
  fi
  if ! jq empty "$f" 2>/dev/null; then
    printf '%s: %s is not valid JSON\n' "$(basename "$0")" "$f" >&2
    exit 1
  fi
done

if jq -e 'has("env")' "$shared" >/dev/null 2>&1; then
  printf '%s: %s has an env block; refusing to merge secrets into a config\n' \
    "$(basename "$0")" "$shared" >&2
  exit 2
fi

jq -s '
  .[0] as $live | .[1] as $shared
  # Every command the shared file is about to install. Anything already pointing
  # at one of these is a leftover from a previous run, not a colleague hook.
  | ([$shared.hooks[]?[]?.hooks[]?.command] | unique) as $ours
  | $live
  | if $shared | has("statusLine") then .statusLine = $shared.statusLine else . end
  | .hooks = (
      reduce ($shared.hooks // {} | to_entries[]) as $e (
        ($live.hooks // {});
        .[$e.key] = (
          ((.[$e.key] // []) | map(select((([.hooks[]?.command]) - $ours) | length > 0)))
          + $e.value)))
  | if (.hooks | length) == 0 then del(.hooks) else . end
' "$live" "$shared"
