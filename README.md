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
│   ├── dev.sh
│   ├── dev-session.sh
│   ├── dev-supabase.sh
│   ├── dev-worktree.sh
│   ├── dev-worktree-up.sh
│   ├── dev-worktree-down.sh
│   └── dev-worktree-env.sh
├── tmux/.tmux.conf
├── zsh/.zshrc
└── install.sh
```

## `dev` CLI

Unified entry point for development tools.

| Command | Alias | Description |
|---------|-------|-------------|
| `dev session` | `dev s` | Tmux dev sessions |
| `dev supabase` | `dev sb` | Shared local Supabase instance |
| `dev worktree` | `dev wt` | Git worktrees with Docker isolation |

### `dev s` — Session

| Command | Description |
|---------|-------------|
| `dev s [dir]` | Create a tmux dev session (claude, nvim, docker windows) |

### `dev sb` — Supabase

| Command | Description |
|---------|-------------|
| `dev sb up` | Start shared Supabase instance |
| `dev sb down [--force]` | Stop shared Supabase instance |
| `dev sb status` | Show Supabase status |
| `dev sb migrate [--reset]` | Apply pending migrations (or reset all) |

### `dev wt` — Worktree

Must be run from inside a bare-cloned repo. Repo name and paths are detected automatically.

| Command | Description |
|---------|-------------|
| `dev wt up <branch>` | Create a git worktree with Docker isolation |
| `dev wt down <branch>` | Tear down a git worktree and free the port |
| `dev wt env` | Set up .env.local for current worktree |

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
