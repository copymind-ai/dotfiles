#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

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

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  ok "Homebrew already installed"
fi

# --- Packages ---
for pkg in tmux neovim; do
  if ! command -v "$pkg" &>/dev/null; then
    info "Installing $pkg..."
    brew install "$pkg"
  else
    ok "$pkg already installed"
  fi
done

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

ok "Done!"
