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
PRE_PULL_HEAD="$(git -C "$DOTFILES" rev-parse HEAD)"
git -C "$DOTFILES" pull --ff-only
POST_PULL_HEAD="$(git -C "$DOTFILES" rev-parse HEAD)"

# Prompt for install.sh re-run if the pulled commits touch it.
# install.sh is the canonical place where new tools, symlinks, or
# /etc/hosts entries get added — if it didn't change, a re-run would
# only do idempotent no-ops.
if [ "$PRE_PULL_HEAD" != "$POST_PULL_HEAD" ] && \
   git -C "$DOTFILES" diff --name-only "$PRE_PULL_HEAD" "$POST_PULL_HEAD" | grep -q '^install\.sh$'; then
  echo ""
  echo "install.sh changed in this update."
  if [ -t 0 ]; then
    read -p "Re-run install.sh now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      exec "$DOTFILES/install.sh"
    fi
    echo "Skipped. Run '$DOTFILES/install.sh' manually when ready."
  else
    echo "Run '$DOTFILES/install.sh' to apply changes."
  fi
fi
