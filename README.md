# dotfiles

Team configuration files for nvim, tmux, ghostty, zsh.

## What's included

| Tool | What it does |
|------|-------------|
| [Ghostty](https://ghostty.org/) | GPU-accelerated terminal emulator |
| [Neovim](https://neovim.io/) | Text editor, used as the primary IDE |
| [tmux](https://github.com/tmux/tmux) | Terminal multiplexer — split panes, persistent sessions |
| [Zsh](https://www.zsh.org/) + [Oh My Zsh](https://ohmyz.sh/) | Shell with plugins, themes, and better defaults |
| [Homebrew](https://brew.sh/) | macOS package manager, installs everything above |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Fast recursive code search, used by Neovim's Telescope |
| [TPM](https://github.com/tmux-plugins/tpm) | Tmux Plugin Manager, auto-installs tmux plugins |

## Structure

```
dotfiles/
├── ghostty/.config/ghostty/
├── neovim/.config/nvim/
├── scripts/
│   └── tmux-dev-session.sh
├── tmux/.tmux.conf
├── zsh/.zshrc
└── install.sh
```

## Dev session

Run `dev` (or `dev ~/path/to/project`) to create a tmux session with preconfigured windows:

- **claude** — two horizontal panes
- **nvim** — editor
- **docker** — container management

If the session already exists, it reattaches instead of creating a duplicate.

## Installation

```bash
git clone https://github.com/copymind-ai/dotfiles.git
cd dotfiles
./install.sh
```

The install script will install all tools from the table above and symlink configs to their expected locations. Existing config files are backed up with a `.bak` suffix before symlinking.

## Adding a new config

1. Move the config file/folder into the dotfiles repo, mirroring the home directory structure
2. Add a `link` entry in `install.sh`
3. Commit and push

## Keeping in sync

```bash
git pull && ./install.sh
```
