# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Path to local binaries
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# Initialize Homebrew tools
eval "$(/opt/homebrew/bin/brew shellenv)"

ZSH_THEME="robbyrussell"

zstyle ':omz:update' mode auto      # update automatically without asking

COMPLETION_WAITING_DOTS="true"

plugins=(git)

source $ZSH/oh-my-zsh.sh

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# bun completions
[ -s "/Users/o.shepel/.bun/_bun" ] && source "/Users/o.shepel/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/bin:$PATH"

# Dev session shortcut — resolves dotfiles root from .zshrc symlink
DOTFILES_DIR="$(dirname $(readlink ~/.zshrc))/.."
alias dev="$DOTFILES_DIR/scripts/tmux-dev-session.sh"
