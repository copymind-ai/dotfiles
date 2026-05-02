#!/usr/bin/env bash
set -euo pipefail

# Test marker: verifying `dev upd` prompts for install.sh re-run.
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
link "$DOTFILES/neovim/.config/nvim"         "$HOME/.config/nvim"
link "$DOTFILES/ghostty/.config/ghostty"     "$HOME/.config/ghostty"

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
