#!/usr/bin/env bash
set -euo pipefail

# Resolve the dotfiles repo from the dev script's own location,
# falling back to the zshrc symlink if needed.
DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$DOTFILES/.git" ]; then
  # Fallback: resolve via ~/.zshrc symlink (mirrors the alias in .zshrc)
  if [ -L "$HOME/.zshrc" ]; then
    DOTFILES="$(cd "$(dirname "$(readlink "$HOME/.zshrc")")" && cd .. && pwd)"
  fi
fi

if [ ! -d "$DOTFILES/.git" ]; then
  echo "error: could not locate dotfiles git repo" >&2
  exit 1
fi

echo "Updating dotfiles at $DOTFILES..."
git -C "$DOTFILES" pull --ff-only
