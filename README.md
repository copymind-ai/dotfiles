# dotfiles

My personal configuration files for nvim, tmux, ghostty, and zsh. Managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Structure

```
dotfiles/
├── nvim/.config/nvim/
├── tmux/.tmux.conf
├── ghostty/.config/ghostty/config
└── zsh/.zshrc
```

## Requirements

```bash
brew install stow
```

Oh My Zsh:

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

## Installation

```bash
git clone https://github.com/copymind-ai/dotfiles.git ~/dotfiles
cd ~/dotfiles
stow neovim
stow tmux
stow ghostty
stow zsh
```

This creates symlinks from the expected config locations to the files in this repo.

## Adding a new config

1. Move the config file/folder into the dotfiles repo, mirroring the home directory structure
2. Run `stow <package>` to create the symlink
3. Commit and push

## Keeping in sync

```bash
# pull latest changes
cd ~/dotfiles && git pull

# push changes after editing configs
cd ~/dotfiles && git add . && git commit -m "update" && git push
```
