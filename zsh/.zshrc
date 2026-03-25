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
