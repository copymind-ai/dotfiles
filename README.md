# dotfiles

Team configuration files for nvim, tmux, ghostty zsh.

## Structure

```
dotfiles/
├── ghostty/.config/ghostty/
├── neovim/.config/nvim/
├── tmux/.tmux.conf
├── zsh/.zshrc
└── install.sh
```

## Installation

```bash
git clone https://github.com/copymind-ai/dotfiles.git
cd dotfiles
./install.sh
```

The install script will:

- Install Homebrew (if missing)
- Install tmux and neovim via brew
- Install Oh My Zsh
- Symlink all configs to their expected locations
- Install TPM and tmux plugins

Existing config files are backed up with a `.bak` suffix before symlinking.

## Adding a new config

1. Move the config file/folder into the dotfiles repo, mirroring the home directory structure
2. Add a `link` entry in `install.sh`
3. Commit and push

## Keeping in sync

```bash
git pull && ./install.sh
```
