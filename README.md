# dotfiles

Team configuration files for local development.

## What's included

| Tool                                                         | What it does                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| [Ghostty](https://ghostty.org/)                              | GPU-accelerated terminal emulator                             |
| [Neovim](https://neovim.io/)                                 | Text editor, used as the primary IDE                          |
| [tmux](https://github.com/tmux/tmux)                         | Terminal multiplexer — split panes, persistent sessions       |
| [Zsh](https://www.zsh.org/) + [Oh My Zsh](https://ohmyz.sh/) | Shell with plugins, themes, and better defaults               |
| [Homebrew](https://brew.sh/)                                 | macOS package manager, installs everything above              |
| [ripgrep](https://github.com/BurntSushi/ripgrep)             | Fast recursive code search, used by Neovim's Telescope        |
| [TPM](https://github.com/tmux-plugins/tpm)                   | Tmux Plugin Manager, auto-installs tmux plugins               |
| [Supabase CLI](https://supabase.com/docs/guides/cli)         | Local Supabase stack, required by `dev sb`                    |
| [Node.js](https://nodejs.org/)                               | Runtime for `pgflow`                                          |
| [Corepack](https://github.com/nodejs/corepack)               | Provides pnpm/yarn shims pinned per-project (ships with Node) |
| [pgflow](https://pgflow.dev/)                                | Flow compiler, required by `dev sb flow`                      |

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
│   ├── dev-supabase-anchor.sh
│   ├── dev-env.sh                # Env-vars dispatcher
│   ├── dev-env-add.sh
│   ├── dev-env-remove.sh
│   ├── dev-env-pull.sh
│   ├── dev-env-push.mjs
│   ├── dev-nanoclaw.sh           # NanoClaw dispatcher
│   ├── dev-nanoclaw-up.sh
│   ├── dev-nanoclaw-down.sh
│   ├── dev-update.sh             # Pull latest dotfiles changes
│   ├── *.helpers.{sh,mjs}        # Sourced libraries (not callable)
│   └── templates/                # File templates used by scripts above
├── tests/
│   ├── unit/                     # Pure function tests
│   ├── integration/              # Single-command tests
│   └── e2e/                      # Multi-command workflows
├── tmux/
│   ├── .tmux.conf
│   ├── monitor.sh                # prefix+M session monitor
│   └── session-select.sh         # prefix+S session picker
├── zsh/.zshrc
├── test.sh                       # Test runner shortcut
└── install.sh
```

## `dev` CLI

Unified entry point for development tools.

| Command        | Alias    | Description                                          |
| -------------- | -------- | ---------------------------------------------------- |
| `dev session`  | `dev s`   | Tmux dev sessions                                    |
| `dev supabase` | `dev sb`  | Shared local Supabase instance                       |
| `dev worktree` | `dev wt`  | Git worktrees with Docker isolation                  |
| `dev env`      | `dev e`   | Env vars across `.env.example`, `.env.local`, Vercel |
| `dev nanoclaw` | `dev nc`  | Manage the NanoClaw host service via launchd        |
| `dev update`   | `dev upd` | Pull latest dotfiles changes                         |

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
| `dev sb anchor`         | Point edge runtime's `COPYMIND_API_HOST` at this worktree's port                                                                         |

### `dev wt` — Worktree

Must be run from inside a bare-cloned repo. Repo name and paths are detected automatically.

| Command                | Description                                                      |
| ---------------------- | ---------------------------------------------------------------- |
| `dev wt init`          | Bootstrap first worktree + port registry from a fresh bare clone |
| `dev wt up <branch>`   | Create a git worktree with Docker isolation                      |
| `dev wt down <branch>` | Tear down a git worktree and free the port                       |
| `dev wt env`           | Set up .env.local for current worktree                           |
| `dev wt port`          | Write docker-compose.override.yml from the port registry         |
| `dev wt info`          | Show info about the current worktree                             |

### `dev e` — Env vars

Manages env vars across three places at once: `.env.example` (committed inventory, flat alphabetical), `.env.local` (gitignored cache), and Vercel (canonical store, all entries written as Plain Text/non-sensitive). Must be run from inside a Vercel-linked worktree.

`--prod` targets `production` + `preview` on Vercel. `--dev` targets `development` only. Default (no flag) targets all three plus `.env.local`.

| Command                             | Description                                                                                                                |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `dev e add [--prod\|--dev] NAME`    | Insert into `.env.example`, prompt for value(s), push to selected Vercel envs as non-sensitive, mirror dev to `.env.local` |
| `dev e remove [--prod\|--dev] NAME` | Remove from selected Vercel envs and `.env.local`. Full remove (no flag) also drops the line from `.env.example`           |
| `dev e pull`                        | Replace `.env.local` with the development env from Vercel (flat alphabetical), backfill local-dev defaults, report drift   |
| `dev e push [--force]`              | Bulk-upload `.env.local` to Vercel `development`. Skips existing keys unless `--force`. `VERCEL_*` keys are always skipped |

`add` / `remove` / `pull` / `push` all talk to Vercel via the REST API, not the `vercel env` CLI — see `dev-env.helpers.mjs`. This bypasses Vercel CLI quirks like the un-skippable preview git-branch prompt (vercel/vercel#15763).

### `dev nc` — NanoClaw

| Command       | Description                                                      |
| ------------- | ---------------------------------------------------------------- |
| `dev nc up`   | Bootstrap NanoClaw via launchd (kickstarts a stale registration) |
| `dev nc down` | Bootout NanoClaw via launchd                                     |

## Session picker

`prefix + S` opens a popup listing every session with a jump key — digits `1`-`9`
first, then `a`-`z`, so switching is one keystroke:

```
 SESSIONS  12

  1  admin                     1w
▸ 2 *dotfiles                  3w
  3 +graspen-course-ai         2w
  ...
  c  zz-other                  1w

  j/k move  h/l column  enter switch  esc cancel
  1-9/a-z jump directly   * here   + attached
```

Either press a session's key, or walk the cursor to it with `j`/`k` (or the
arrow keys) and hit `enter`. The cursor's row is highlighted (shown above as
`▸`, which is also drawn, so the cursor survives a terminal with no colors), and
it starts on the session you are already in. `h`/`l` step a whole column, so
they do nothing while the list is one column wide. `esc` cancels; any other key
is ignored rather than closing the popup under you.

`*` marks the session this client is on, `+` one another client is attached to,
and the last column counts windows. Only the client that opened the picker
moves.

Notes:

- Replaces tmux's own `choose-session`, whose labels start at `0` and switch to
  `M-a` from the tenth entry on, and are not configurable.
- Sessions are listed alphabetically, so the keys are stable between openings —
  they only shift when a session is created or destroyed. The cursor follows the
  session it is on, not its index, so a session appearing or going away while the
  popup is open does not move it.
- A list too tall for the client flows into up to three columns, filled top to
  bottom, rather than scrolling the first keys off the top. A client too short
  even for that loses the header first, and says `... N more` if entries still
  do not fit.
- `h`, `j`, `k` and `l` are left out of the jump keys because they drive the
  cursor. Past the 31st session there are no keys left; those are listed, and
  reachable with the cursor.
- Tunables: `PICKER_FILTER` (regex; list only matching sessions),
  `PICKER_WIDTH` (popup width, default 56), `PICKER_COLW` (width of one column
  once there is more than one, default 30).

## Session monitor

`prefix + M` opens the `monitor` session: one line per tmux session, showing what
its Claude window is doing right now.

```
 MONITOR  15 sessions  11 claude  1 working  1 need you  refresh 2s

  1  admin                   shell      12d3h
  2  article                 draft      1d22h  let's draft §3 now
▸ 3  copyclaw                NEEDS YOU     1m  Do you want to make this edit to auth.ts?
  4  dotfiles                working       4s  Cooking…
  5  graspen-course-ai       idle         13m  2 agents
  ...
  f  zz-other                other         2s  sleep

  j/k move   enter jump   1-9/a-z jump directly   r refresh   q quit
```

Press a session's key to jump to it, or move the cursor with `j`/`k` (or the
arrow keys) and hit `enter`. The cursor's row is highlighted (shown above as `▸`,
which is also drawn, so the cursor survives a terminal with no colors). Only the
client showing the monitor moves, so other attached clients are left where they
are. `q` or `esc` closes the monitor.

`h`, `j`, `k` and `l` are left out of the jump keys because they drive the
cursor — `h`/`l` do nothing here, the list being one column — and so are `q` and
`r`. The cursor stays on its session across refreshes, even as sessions come and
go and the keys shift under it.

| State       | Means                                                    |
| ----------- | -------------------------------------------------------- |
| `working`   | Claude is generating (`esc to interrupt` on screen)      |
| `NEEDS YOU` | waiting on a permission or plan prompt                   |
| `draft`     | text typed into the prompt but not sent                  |
| `idle`      | up with an empty prompt (detail shows background agents) |
| `shell`     | just a shell                                             |
| `other`     | something else running; detail names the command         |
| `gone`      | session or window disappeared                            |

Which window each session is judged by, in order: one actually running Claude,
else one named `claude`, else the session's active window. Claude Code reports its
version as its process name (`2.1.222`), which is how it is recognised — so a
window auto-renamed away from `claude` is still found.

Notes:

- State is derived by polling `capture-pane`, so the monitor never attaches a
  client to the monitored sessions and cannot resize or disturb them.
- `N agents` in Claude's footer stays on screen while it is idle, so it is
  reported as detail, not as a busy state.
- The patterns live in `monitor_classify()` in `tmux/monitor.sh` — the one place to
  fix if a Claude Code release reworks its footer.
- Tunables: `MONITOR_INTERVAL` (seconds, default 2), `MONITOR_WINDOW` (preferred
  window name, default `claude`), `MONITOR_FILTER` (regex; list only matching
  sessions, e.g. `^graspen-`), `MONITOR_SESSION` (default `monitor`).
- `prefix + M` replaces tmux's default "clear marked pane"; `prefix + m` still
  toggles a mark.

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
