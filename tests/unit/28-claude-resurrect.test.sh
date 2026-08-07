#!/usr/bin/env bash
# tmux/claude-save.sh must turn Claude's session registry into a map keyed by
# coordinates tmux-resurrect will recreate, and tmux/claude-restore.sh must turn
# that map back into the right `claude` invocation -- or refuse to, which is the
# half worth testing. A wrong id here silently reopens somebody else's
# conversation, so every guard gets a case.
#
# claude-restore.sh is exercised through a stub `claude` on PATH that records its
# arguments instead of running: the script's whole job is to decide those
# arguments and then exec, so the arguments are the observable behaviour. The stub
# also stands in for tmux, since the script asks it for the pane coordinates and
# the test has no tmux server to ask.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: Claude session restore${RESET}\n"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SAVE="$ROOT/tmux/claude-save.sh"
RESTORE="$ROOT/tmux/claude-restore.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TAB=$'\t'

# ── claude-save.sh ────────────────────────────────────────────────────
#
# Faked at both inputs: a registry directory of JSON files, and a `tmux` on PATH
# that answers `list-panes` from a fixture. Nothing here needs a server.

mkdir -p "$TMP/bin" "$TMP/sessions"
cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Only list-panes is asked for, and only with the one format.
[ "${1:-}" = "list-panes" ] && cat "$FAKE_PANES"
EOF
chmod +x "$TMP/bin/tmux"

# <name> <sessionId> <cwd> <tmux field>
registry_entry() {
  printf '{"pid":1,"sessionId":"%s","cwd":"%s","tmux":"%s"}\n' "$2" "$3" "$4" \
    > "$TMP/sessions/$1.json"
}

run_save() {
  PATH="$TMP/bin:$PATH" \
  FAKE_PANES="$TMP/panes" \
  CLAUDE_SESSION_DIR="$TMP/sessions" \
  CLAUDE_RESURRECT_MAP="$TMP/map" \
    bash "$SAVE"
}

cat > "$TMP/panes" <<'EOF'
%10 dotfiles:1.1
%11 dotfiles:2.1
%20 article:1.1
%21 article:1.2
EOF

header "claude-save.sh writes one line per live session"
rm -f "$TMP/sessions"/*.json
registry_entry a aaaa-1 /home/u/dotfiles "dotfiles:@1.%10"
registry_entry b bbbb-2 /home/u/article  "article:@9.%20"
run_save
assert_eq "dotfiles pane resolved to its coordinates" \
  "dotfiles:1.1${TAB}/home/u/dotfiles${TAB}aaaa-1" \
  "$(grep '^dotfiles:' "$TMP/map")"
assert_eq "article pane resolved to its coordinates" \
  "article:1.1${TAB}/home/u/article${TAB}bbbb-2" \
  "$(grep '^article:' "$TMP/map")"

# The case `claude --continue` cannot express, and the reason the map exists at
# all: two conversations, one directory, two panes.
header "two sessions in one directory stay distinct"
rm -f "$TMP/sessions"/*.json
registry_entry a first-id  /home/u/article "article:@9.%20"
registry_entry b second-id /home/u/article "article:@9.%21"
run_save
assert_eq "both panes recorded" 2 "$(grep -c '^article:' "$TMP/map")"
assert_eq "pane 1 keeps its own id" "first-id"  "$(awk -F'\t' '$1=="article:1.1"{print $3}' "$TMP/map")"
assert_eq "pane 2 keeps its own id" "second-id" "$(awk -F'\t' '$1=="article:1.2"{print $3}' "$TMP/map")"

header "claude-save.sh drops what it cannot place"
rm -f "$TMP/sessions"/*.json
registry_entry gone    id-gone    /home/u/x "x:@1.%99"       # pane not on this server
registry_entry nopane  id-nopane  /home/u/x ""               # no tmux field at all
registry_entry nocwd   id-nocwd   ""        "dotfiles:@1.%10"
registry_entry garbage id-garbage /home/u/x "dotfiles:@1.abc" # not a pane id
registry_entry good    id-good    /home/u/dotfiles "dotfiles:@1.%10"
run_save
assert_eq "only the placeable session survives" 1 "$(grep -c . "$TMP/map")"
assert_contains "and it is the right one" "id-good" "$(cat "$TMP/map")"

header "claude-save.sh replaces the map rather than appending"
rm -f "$TMP/sessions"/*.json
registry_entry a aaaa-1 /home/u/dotfiles "dotfiles:@1.%10"
run_save; run_save
assert_eq "two runs leave one line" 1 "$(grep -c . "$TMP/map")"
assert "no temp file left behind" bash -c "! ls '$TMP'/map.* >/dev/null 2>&1"

header "claude-save.sh survives an empty registry"
rm -f "$TMP/sessions"/*.json
run_save
assert_eq "map is emptied, not stale" 0 "$(grep -c . "$TMP/map" || true)"

# ── claude-restore.sh ─────────────────────────────────────────────────

mkdir -p "$TMP/rbin" "$TMP/projects/proj"
cat > "$TMP/rbin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CLAUDE_ARGS_LOG"
EOF
chmod +x "$TMP/rbin/claude"

# The script asks tmux for its own coordinates and nothing else.
cat > "$TMP/rbin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "display-message" ] && printf '%s\n' "$FAKE_COORDS"
EOF
chmod +x "$TMP/rbin/tmux"

transcript() { : > "$TMP/projects/proj/$1.jsonl"; }

# <coords> <cwd> -> the arguments claude was given
restore_in() {
  ( cd "$2" && \
    PATH="$TMP/rbin:$PATH" \
    TMUX="fake,1,0" \
    FAKE_COORDS="$1" \
    CLAUDE_ARGS_LOG="$TMP/args" \
    CLAUDE_RESURRECT_MAP="$TMP/rmap" \
    CLAUDE_PROJECTS_DIR="$TMP/projects" \
      bash "$RESTORE" )
  cat "$TMP/args"
}

mkdir -p "$TMP/w/dotfiles" "$TMP/w/article" "$TMP/w/elsewhere" \
         "$TMP/w/unmapped" "$TMP/w/unclaimed"
transcript live-id
{
  printf 'dotfiles:1.1\t%s\tlive-id\n'     "$TMP/w/dotfiles"
  printf 'article:1.1\t%s\tarticle-one\n'  "$TMP/w/article"
  printf 'article:1.2\t%s\tarticle-two\n'  "$TMP/w/article"
  printf 'stale:1.1\t%s\tdeleted-id\n'     "$TMP/w/elsewhere"
} > "$TMP/rmap"

header "claude-restore.sh resumes the session its pane had"
assert_eq "coordinates + directory agree -> resume by id" \
  "--resume live-id" "$(restore_in dotfiles:1.1 "$TMP/w/dotfiles")"

header "claude-restore.sh refuses an id it cannot stand behind"
# A pane whose layout was edited by hand since the save, or a record written by a
# second tmux server that happens to use the same coordinates.
assert_eq "right coordinates, wrong directory -> not that id" \
  "--continue" "$(restore_in dotfiles:1.1 "$TMP/w/unmapped")"
assert_eq "recorded id whose transcript is gone -> fresh" \
  "" "$(restore_in stale:1.1 "$TMP/w/elsewhere")"

header "claude-restore.sh falls back on an unrecorded pane"
assert_eq "nothing claims this directory -> continue the newest" \
  "--continue" "$(restore_in new:1.1 "$TMP/w/unclaimed")"
assert_eq "another pane claims this directory -> fresh, not a duplicate" \
  "" "$(restore_in new:1.1 "$TMP/w/article")"

header "claude-restore.sh degrades to a plain claude"
rm -f "$TMP/rmap"
assert_eq "no map at all -> continue" "--continue" "$(restore_in any:1.1 "$TMP/w/dotfiles")"
printf 'bad:1.1\t%s\tid;rm -rf /\n' "$TMP/w/dotfiles" > "$TMP/rmap"
assert_eq "id carrying shell metacharacters is not resumed" \
  "" "$(restore_in bad:1.1 "$TMP/w/dotfiles")"

# ── The wiring the two halves depend on ──────────────────────────────
#
# Both scripts are useless unless resurrect is told to call them, and the option
# has to survive resurrect's `eval set` -- so this asserts the exact string
# rather than merely that something is set.

header ".tmux.conf wires both hooks into resurrect"
CONF="$ROOT/tmux/.tmux.conf"
assert_contains "claude is on the restore list, matched loosely" \
  "@resurrect-processes '\"~claude->~/.tmux/claude-restore.sh\"'" "$(cat "$CONF")"
assert_contains "the map is written from the post-save hook" \
  "@resurrect-hook-post-save-all '~/.tmux/claude-save.sh'" "$(cat "$CONF")"
# Continuum's auto-restore fires during tpm's run, and would otherwise restore
# against the default process list.
assert "options are set before tpm loads" bash -c \
  "[ \$(grep -n '@resurrect-processes' '$CONF' | cut -d: -f1) -lt \
     \$(grep -n \"run '~/.tmux/plugins/tpm/tpm'\" '$CONF' | cut -d: -f1) ]"

header "install.sh links both scripts"
assert_contains "claude-save.sh"    "tmux/claude-save.sh"    "$(cat "$ROOT/install.sh")"
assert_contains "claude-restore.sh" "tmux/claude-restore.sh" "$(cat "$ROOT/install.sh")"

# ── exec, which is the one thing that cannot regress quietly ─────────
#
# resurrect works out what a pane was running by asking ps for the shell's child.
# If claude-restore.sh ever calls claude instead of exec'ing it, the wrapper stays
# in between, the next save records the wrapper's name, "~claude" stops matching,
# and every pane restores exactly once and never again -- with nothing broken
# anywhere a test would normally look.

header "claude-restore.sh always execs"
# Every line that runs claude as a command, minus the ones that exec it. Anything
# left is the regression.
runs=$(grep -cE '^[[:space:]]*claude([[:space:]]|$)|^[[:space:]]*exec[[:space:]]+claude([[:space:]]|$)' "$RESTORE" || true)
execs=$(grep -cE '^[[:space:]]*exec[[:space:]]+claude([[:space:]]|$)' "$RESTORE" || true)
assert_eq "no invocation of claude without exec" "$runs" "$execs"
assert "and there is at least one" bash -c "[ '$execs' -gt 0 ]"

print_results
