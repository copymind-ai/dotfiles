#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# Work from a world-readable dir so Homebrew's sandbox can stat the CWD.
cd /tmp

info() { printf '\033[1;34m[info]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$1"; }

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    warn "$dst already exists, backing up to ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  ok "linked $dst -> $src"
}

# --- Sudo priming ---
# Two steps in this script need root:
#
#   1. Homebrew install (first run only). The Homebrew installer creates
#      /opt/homebrew (Apple Silicon) or /usr/local (Intel) owned by the
#      current user, and triggers `xcode-select --install` — both require
#      sudo. On re-runs, brew is already present and this step is skipped.
#
#   2. Appending `127.0.0.1 host.docker.internal` to /etc/hosts. /etc/hosts
#      is root-owned (mode 644), so `tee -a` must run under sudo. Skipped
#      if the entry is already present.
#
# `brew install <pkg>`, npm global installs into the Homebrew prefix,
# Oh My Zsh, TPM, and symlinks under $HOME all run as the user — no sudo.
#
# We prompt for the password upfront so the rest of the run is unattended,
# and keep the timestamp alive in the background until this script exits.
if ! sudo -n true 2>/dev/null; then
  info "This install needs sudo for Homebrew setup and /etc/hosts — prompting now."
  sudo -v
fi
(
  while kill -0 "$$" 2>/dev/null; do
    sudo -n true 2>/dev/null || exit
    sleep 60
  done
) &

# --- Homebrew ---
# NONINTERACTIVE=1 skips the installer's "Press RETURN" prompt and makes its
# sudo-access check use `sudo -n -l mkdir`, so it reuses our cached ticket
# from `sudo -v` above instead of re-prompting for the password.
if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  ok "Homebrew already installed"
fi

# --- Packages ---
for pkg in tmux neovim ripgrep jq node; do
  if ! command -v "$pkg" &>/dev/null; then
    info "Installing $pkg..."
    brew install "$pkg"
  else
    ok "$pkg already installed"
  fi
done

# --- Corepack (pnpm/yarn shims pinned per-project via packageManager) ---
# Ships with the brew `node` formula. `corepack enable` writes shims into the
# Homebrew prefix's bin/ — user-owned, so no sudo. Idempotent: re-running just
# rewrites the shims. We gate on `pnpm` existing to keep the script's
# "installed / already installed" output symmetric.
if command -v corepack &>/dev/null; then
  # Bundled corepack ships with pnpm/yarn signing keys that go stale and
  # break `corepack enable` with "Cannot find matching keyid". Update first
  # so the shims can verify pnpm. No-op when already on latest.
  info "Updating Corepack..."
  npm install -g corepack@latest
  if ! command -v pnpm &>/dev/null; then
    info "Enabling Corepack shims (pnpm, yarn)..."
    corepack enable
  else
    ok "Corepack shims already enabled"
  fi
else
  warn "corepack not found (expected to ship with node) — skipping"
fi

# --- Supabase CLI ---
if ! command -v supabase &>/dev/null; then
  info "Installing Supabase CLI..."
  brew install supabase/tap/supabase
else
  ok "Supabase CLI already installed"
fi

# --- pgflow (required by `dev sb flow`) ---
if ! command -v pgflow &>/dev/null; then
  info "Installing pgflow globally..."
  npm install -g pgflow
else
  ok "pgflow already installed"
fi

# --- Ghostty ---
# A cask, not a formula, so it can't join the package loop above. Gated on the
# app bundle rather than `command -v ghostty`: the CLI binary lives inside the
# bundle and isn't on PATH, so a `command -v` check would reinstall every run.
# The config itself is symlinked further down.
if [ -d "/Applications/Ghostty.app" ] || [ -d "$HOME/Applications/Ghostty.app" ]; then
  ok "Ghostty already installed"
else
  info "Installing Ghostty..."
  brew install --cask ghostty
fi

# --- Oh My Zsh ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  info "Installing Oh My Zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  ok "Oh My Zsh already installed"
fi

# --- Symlinks ---
info "Creating symlinks..."
link "$DOTFILES/zsh/.zshrc"                  "$HOME/.zshrc"
link "$DOTFILES/tmux/.tmux.conf"             "$HOME/.tmux.conf"
link "$DOTFILES/tmux/monitor.sh"             "$HOME/.tmux/monitor.sh"
link "$DOTFILES/tmux/session-select.sh"      "$HOME/.tmux/session-select.sh"
link "$DOTFILES/neovim/.config/nvim"         "$HOME/.config/nvim"
link "$DOTFILES/ghostty/.config/ghostty"     "$HOME/.config/ghostty"
link "$DOTFILES/claude/statusline.sh"        "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/monitor-hook.sh"      "$HOME/.claude/monitor-hook.sh"

# --- Claude Code settings ---
# settings.json is merged rather than symlinked. Claude writes to it itself --
# /model, permission changes and enabled plugins all land there -- so a symlink
# would either be replaced behind your back or drag every runtime toggle into git
# as a dirty working tree.
#
# Exactly two things are shared -- the status line and the hooks -- because those
# are what the tmux monitor reads. Everything else in that file belongs to
# whoever owns the laptop: editor mode, model, plugins, notifications, the env
# block with its tokens, and above all the permission posture (defaultMode and
# the skip* prompts, which decide how much Claude does without asking). None of
# it is tracked, and the merge below cannot touch a key it does not mention.
#
# statusLine is replaced outright; there is only one of it. Hooks are appended
# per event instead, because a colleague may well have their own PostToolUse
# formatter and a plain merge would drop it -- the arrays live under the same key.
# Any entry pointing at our own script is dropped first, so re-running does not
# stack up duplicates.
info "Merging Claude Code status line and hooks..."
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SHARED="$DOTFILES/claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
if ! jq empty "$CLAUDE_SETTINGS" 2>/dev/null; then
  warn "$CLAUDE_SETTINGS is not valid JSON — skipping, fix it and re-run"
elif jq -e 'has("env")' "$CLAUDE_SHARED" >/dev/null 2>&1; then
  # A tracked env block is how a secret would reach the remote. Refuse rather
  # than merge it, and say why.
  warn "$CLAUDE_SHARED has an env block — refusing to merge it"
  warn "keep secrets in the live ~/.claude/settings.json, which is never committed"
else
  # Someone else's status line is the one thing here that gets displaced, so say
  # so rather than let it vanish quietly.
  PREV_SL=$(jq -r '.statusLine.command // ""' "$CLAUDE_SETTINGS")
  NEW_SL=$(jq -r '.statusLine.command // ""' "$CLAUDE_SHARED")
  if [ -n "$PREV_SL" ] && [ "$PREV_SL" != "$NEW_SL" ]; then
    warn "replacing your status line ($PREV_SL) — the old settings.json is at ${CLAUDE_SETTINGS}.bak"
  fi
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  # The merge itself lives in claude/merge-settings.sh so it can be tested
  # directly -- tests/unit/04-claude-settings-merge.test.sh runs it over a set of
  # configs and checks nothing is lost. Written to a temp file first: a failure
  # part way through must not leave a truncated settings.json behind.
  if "$DOTFILES/claude/merge-settings.sh" "$CLAUDE_SETTINGS.bak" "$CLAUDE_SHARED" \
       > "$CLAUDE_SETTINGS.tmp"; then
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
    ok "Claude Code status line + hooks installed (everything else left alone)"
  else
    rm -f "$CLAUDE_SETTINGS.tmp"
    warn "merging Claude settings failed — left ${CLAUDE_SETTINGS} untouched"
  fi
fi

# User-level skills, one symlink each so Claude's own additions can live
# alongside the tracked ones.
mkdir -p "$HOME/.claude/skills"
for skill in "$DOTFILES"/claude/skills/*/; do
  [ -d "$skill" ] || continue
  link "${skill%/}" "$HOME/.claude/skills/$(basename "$skill")"
done

# --- TPM ---
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
  info "Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
else
  ok "TPM already installed"
fi
info "Installing tmux plugins..."
"$HOME/.tmux/plugins/tpm/bin/install_plugins"

# --- /etc/hosts: host.docker.internal ---
# Docker worktrees write NEXT_PUBLIC_SUPABASE_URL using host.docker.internal
# so the same URL works from the browser (host) and inside the container.
# Docker Desktop doesn't reliably add this entry to the host's /etc/hosts,
# so ensure it exists.
if grep -qE '^[^#]*[[:space:]]host\.docker\.internal([[:space:]]|$)' /etc/hosts; then
  ok "/etc/hosts already maps host.docker.internal"
else
  info "Adding host.docker.internal to /etc/hosts (requires sudo)..."
  echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts >/dev/null
  ok "Added host.docker.internal -> 127.0.0.1"
fi

ok "Done!"
