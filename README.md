# dotfiles

Team configuration files for local development.

## What's included

| Tool                                                         | What it does                                            |
| ------------------------------------------------------------ | ------------------------------------------------------- |
| [Ghostty](https://ghostty.org/)                              | GPU-accelerated terminal emulator                       |
| [Neovim](https://neovim.io/)                                 | Text editor, used as the primary IDE                    |
| [tmux](https://github.com/tmux/tmux)                         | Terminal multiplexer — split panes, persistent sessions |
| [Zsh](https://www.zsh.org/) + [Oh My Zsh](https://ohmyz.sh/) | Shell with plugins, themes, and better defaults         |
| [Homebrew](https://brew.sh/)                                 | macOS package manager, installs everything above        |
| [ripgrep](https://github.com/BurntSushi/ripgrep)             | Fast recursive code search, used by Neovim's Telescope  |
| [TPM](https://github.com/tmux-plugins/tpm)                   | Tmux Plugin Manager, auto-installs tmux plugins         |
| [Supabase CLI](https://supabase.com/docs/guides/cli)         | Local Supabase stack, required by `dev sb`              |
| [Node.js](https://nodejs.org/)                               | Runtime for `pgflow`                                    |
| [Corepack](https://github.com/nodejs/corepack)               | Provides pnpm/yarn shims pinned per-project (ships with Node) |
| [pgflow](https://pgflow.dev/)                                | Flow compiler, required by `dev sb flow`                |

## Structure

```
dotfiles/
├── ghostty/.config/ghostty/
├── neovim/.config/nvim/
├── scripts/
│   ├── dev.sh                    # Entry point
│   ├── dev-session.sh            # Tmux sessions
│   ├── dev-worktree.sh           # Worktree dispatcher
│   ├── dev-worktree-init.sh
│   ├── dev-worktree-up.sh
│   ├── dev-worktree-down.sh
│   ├── dev-worktree-env.sh
│   ├── dev-worktree-port.sh
│   ├── dev-worktree-info.sh
│   ├── dev-supabase.sh           # Supabase dispatcher
│   ├── dev-supabase-helpers.sh   # Shared functions
│   ├── dev-supabase-up.sh
│   ├── dev-supabase-down.sh
│   ├── dev-supabase-status.sh
│   ├── dev-supabase-link.sh
│   ├── dev-supabase-unlink.sh
│   ├── dev-supabase-sync.sh
│   ├── dev-supabase-migrate.sh
│   ├── dev-supabase-seed.sh
│   ├── dev-supabase-reset.sh
│   ├── dev-supabase-flow.sh
│   └── templates/                # File templates used by scripts above
├── tests/
│   ├── unit/                     # Pure function tests
│   ├── integration/              # Single-command tests
│   └── e2e/                      # Multi-command workflows
├── tmux/.tmux.conf
├── zsh/.zshrc
├── test.sh                       # Test runner shortcut
└── install.sh
```

## `dev` CLI

Unified entry point for development tools.

| Command        | Alias    | Description                         |
| -------------- | -------- | ----------------------------------- |
| `dev session`  | `dev s`  | Tmux dev sessions                   |
| `dev supabase` | `dev sb` | Shared local Supabase instance      |
| `dev worktree` | `dev wt` | Git worktrees with Docker isolation |

### `dev s` — Session

| Command       | Description                                              |
| ------------- | -------------------------------------------------------- |
| `dev s [dir]` | Create a tmux dev session (claude, nvim, docker windows) |

### `dev sb` — Supabase

All commands operate on the shared supabase worktree regardless of which worktree you invoke them from.

| Command                 | Description                                                                                                                              |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `dev sb up`             | Create supabase worktree and start Supabase                                                                                              |
| `dev sb down [--force]` | Stop shared Supabase instance                                                                                                            |
| `dev sb status`         | Show Supabase status                                                                                                                     |
| `dev sb link`           | Symlink current worktree's migrations and apply                                                                                          |
| `dev sb unlink`         | Remove current worktree's migration symlinks                                                                                             |
| `dev sb sync [--reset]` | Fetch origin/main, update supabase worktree, clean stale symlinks                                                                        |
| `dev sb migrate`        | Apply pending migrations in the shared worktree                                                                                          |
| `dev sb seed`           | Apply pending seeds from `supabase/seeds/` (skips `users.sql`; tracked in `supabase_seeds.applied_seeds` — rename a seed to re-apply it) |
| `dev sb reset`          | Full local reset: `db reset` → apply migrations → seed `users.sql` → apply seeds → background `functions serve`                          |
| `dev sb flow [slug]`    | Compile pgflow flows from the invoking worktree and apply against the shared stack.                                                      |

### `dev wt` — Worktree

Must be run from inside a bare-cloned repo. Repo name and paths are detected automatically.

| Command                | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `dev wt init`          | Bootstrap first worktree + port registry from a fresh bare clone   |
| `dev wt up <branch>`   | Create a git worktree with Docker isolation                        |
| `dev wt down <branch>` | Tear down a git worktree and free the port                         |
| `dev wt env`           | Set up .env.local for current worktree                             |
| `dev wt port`          | Write docker-compose.override.yml from the port registry           |
| `dev wt info`          | Show info about the current worktree                               |

## Testing

```bash
./test.sh                    # all tests
./test.sh --unit             # unit only (no Docker/Supabase needed)
./test.sh --integration      # integration only
./test.sh --e2e              # e2e only
./test.sh link               # pattern filter
```

Requires everything `install.sh` sets up (`supabase`, `jq`, `pgflow`, `node`, …) plus `psql`, `rsync`, `curl`, `docker`. Run `./install.sh` before the first test run.

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
