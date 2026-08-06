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
├── claude/
│   ├── settings.json              # Shared: statusLine + hooks only, nothing else
│   ├── merge-settings.sh          # Merges the above into an existing config
│   ├── statusline.sh              # Status line + context/cost export + spend ledger
│   ├── monitor-hook.sh            # Claude Code hooks -> session state + subagent count
│   └── skills/                    # User-level skills, symlinked one by one
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
 MONITOR  15 sessions  11 claude  1 working  1 need you  5 agents  refresh 2s  5h 17% to 5:20PM  7d 28% to Tue 11PM

  1  admin                   shell
  2  article                 draft           12%    $4.10  let's draft §3 now
▸ 3  copyclaw                NEEDS YOU       61%   $22.65  Do you want to make this edit to auth.ts?
  4  dotfiles                working         40%   $40.90  Cooking…
  5  graspen-ci              idle        5a  14%   $41.61  Fix CI failure for course translation
  6  graspen-course-ai       idle            35%   $39.75  Check AI-at-work course generation status
  ...
  f  zz-other                other                  sleep
                               total active  $499.01  sub ~$487.01   api $12.00     extra ~$4.25
                                      today  $541.20  sub ~$521.20   api $20.00
                                         7d $1180.05  sub ~$1140.05  api $40.00
                                        30d $2620.11  sub ~$2540.11  api $80.00
                                        all $8841.66  sub ~$8601.66  api $240.00

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

| State       | Means                                            |
| ----------- | ------------------------------------------------ |
| `working`   | Claude is generating                             |
| `NEEDS YOU` | waiting on a permission, plan or select prompt   |
| `draft`     | text typed into the prompt but not sent          |
| `idle`      | up with an empty prompt; detail is its last task |
| `shell`     | just a shell                                     |
| `other`     | something else running; detail names the command |
| `gone`      | session or pane disappeared                      |

Two columns come from the status line rather than the screen: how much of the
context window that session has used, and what it has cost. Both are blank for a
session that has not answered yet or has no exporter installed — blank means
unknown, which is not the same as zero.

`5a` is the third: how many subagents that session has in flight, and `5 agents`
in the header is the fleet's. Blank at zero, so it only shows up where something
is actually running — see [counting subagents](#counting-subagents). It is the one
number here that says nothing about the state beside it: a session that has handed
five background agents their work and gone quiet reads `idle 5a`, and that is
right. It will answer you now; its fleet is still busy.

Under the rows is one line per window, each totalling the cost column over a
longer reach than the one above it:

- **`active`** — the sessions on screen, added up. The only row that dies with
  them. It also carries the word `total` for the block; the rows under it are the
  same total over a longer reach, so they do not repeat it.
- **`today`**, **`7d`**, **`30d`**, **`all`** — every session that has run in
  that window, whether or not it is still up. `7d` and `30d` are calendar days
  including today, so `7d` on a Monday reaches back to the previous Tuesday.
  These come from the ledger — see [spend over time](#spend-over-time).

`active` and `today` overlap on purpose: the live sessions are part of the day
they are running in. Each row is then split by how the spend was paid for:

- **`sub ~$487.01`** — what the subscription absorbed, priced at API rates.
  **This is not a bill.** On a subscription nothing is charged for it; the window
  percentages are the real constraint. The tilde is there because it is an
  estimate of a price nobody charged.
- **`api $12.00`** — spend from a session authenticated to an API-billed account
  instead of the subscription. No tilde: that figure is money.
- **`extra ~$4.25`** — spend attributed to a window that was already full. Only
  `active` can show it: it is worked out from the live exports, and the ledger
  records what was spent rather than how.

A column is left blank when nothing landed in it, the same as an empty cost cell
in the rows above — no api spend and no api sessions look alike from here, and
neither is worth a `$0.00`. A row whose spend never got classified still counts
in its total, so a total can exceed `sub` plus `api`.

Sessions are sorted into `sub`/`api` by whether Claude sends them `rate_limits`,
which only goes to a Claude.ai subscription. A personal subscription never
crosses over on its own: hitting the limit stops the session and tells you to run
`/login` for an API-billed account, so anything landing in `api` got there
because someone chose it. A session that has not answered yet counts toward
neither.

The header keeps what is account-wide, since every session reports the same pair:

- **`5h 17% to 5:20PM`** — the rolling five-hour subscription window and when it
  clears. This is the one that bites when several sessions run at once; it falls
  on its own as older usage rolls out of the window.
- **`7d 28% to Tue 11PM`** — the weekly window. Only really moves one way until
  it resets.
- **`5h 100% FULL`** — the window is exhausted. Utilization is clamped upstream,
  so 100 is as high as it goes.
- **`** You're close to your usage limit`** — a limit notice read off some
  session's screen.

### Spend over time

The `active` row only knows about sessions that are still up, because it adds up
the cost column and that comes from the per-pane exports, which the next session
in that pane overwrites. So `claude/statusline.sh` also keeps a ledger, in
`~/.claude/monitor/spend`: one small file per session per day, named
`<day>.<session id>`, holding the cents that session spent on that day and
whether it was paying by subscription or by API key.

Each write compares the session's cumulative cost against what the file last
saw and adds the difference. On the first write of a new day the figure to
measure against is carried over from the day that session wrote before, or a
session left running past midnight would drop its whole history onto the new day.
A `/clear` or a resume taking the cost backwards rebases instead of accruing a
negative.

The monitor sums today's files on every tick and the older ones once a day —
days before today cannot change — so the four rows cost a handful of file reads
and no forks.

Worth knowing:

- **It starts when it is installed.** There is no history before the first write;
  the numbers are only complete from that day forward.
- **It counts sessions outside tmux too.** The ledger is keyed by session id
  rather than by pane, so anything running `claude` on this machine lands in it.
  That also means it is this machine only.
- **`today` overlaps `active`.** The live sessions are part of the day they are
  running in, and are counted in both rows.
- **A session already running when it was installed** had no earlier file to
  carry from, so its history up to that point landed on that first day. Once,
  at install, and only for what was already up.
- **Nothing is ever pruned.** A few dozen files a day is nothing until it is;
  `rm ~/.claude/monitor/spend/2025-*` is the whole cleanup story, at the cost of
  those days leaving `all`.

### Extra usage

The `extra` column is inferred, from two independent sides:

- **Arithmetic**, in `claude/statusline.sh`: each run compares the session's cost
  against its own last export and files the difference under whether a window
  read full when it was earned. Handles a window resetting mid-session, and a
  `/clear` taking the cost back to zero.
- **The screen**, in `monitor_scan_notice()`: the notices Claude renders near the
  overage cap or after a refusal — "close to your usage limit", "out of extra
  usage", "hit your monthly spend limit" — matched as whole phrases, and only in
  the bottom few rows, since the transcript above is full of sentences that would
  otherwise match.

One caveat once extra usage is switched on. The API can report the weekly window
as `seven_day_overage_included`, with the overage headroom folded into the
denominator — in which case it may never read 100 while overage is being spent,
and the arithmetic under-counts. Treat `extra` as a floor, and
`CLAUDE_OVERAGE_AT` (default 100) as the knob if the percentage behaves
differently.

### Counting subagents

`5a` in a row is how many subagents that session has in flight, and `5 agents` in
the header is the fleet's.

There is nothing on the screen to count: Claude's fleet view lists agents only
while it is open, and it is not on screen at all in a session nobody is looking at.
Claude's own events do carry it. `SubagentStart` and `SubagentStop` each name the
agent they are about, and `Stop` and `SubagentStop` both carry the whole
background-task registry.

So `claude/monitor-hook.sh` keeps a directory per pane,
`~/.claude/monitor/<server pid>-<pane>.agents`, holding one empty file named for
each agent in flight. The count is however many files are in it, which costs the
monitor a glob and no forks at all. Files rather than a number in a file because
five agents spawned in one turn is five copies of the hook running at once, and a
number would need a read, an add and a write between them.

The registry is what keeps it honest, at two points:

- **Every `Stop`** reconciles the directory against it in both directions. `Stop`
  fires once the main loop has finished, so nothing foreground can still be up: a
  marker with nothing behind it is a leftover — an agent killed before its stop
  event, or a session already running a fleet when the hooks were installed — and
  can go.
- **Every `SubagentStop`** adopts anything the registry names that has no marker,
  and drops nothing but the agent that just stopped. Additive only, because that
  snapshot excludes foreground agents and removing on it would take out every
  foreground agent running in parallel. This is what stops a catch-up from waiting
  out a turn — under a fleet, a session can stay busy for an hour.

Unlike the exported state, the count is never aged out. A session that hands five
background agents their work and goes quiet stops writing state long before they
finish, and expiring the count would blank it on exactly the sessions it exists
for. What guards it instead is the pane: a pane with no Claude in it counts
nothing, whatever is left in its directory, so a fleet whose session was killed
outright stops being reported rather than sitting there forever.

Worth knowing:

- **A stopped clock in the fleet view is not a finished agent.** It is idle between
  turns and can be woken with a queued message, which restarts its clock. Claude's
  registry still counts it, so this does too — the count and the fleet list agree.
- **It needs the hooks.** A session running on a machine without them counts
  nothing. A session that was already up when they were merged in does pick them
  up — Claude Code re-reads `settings.json` — but a fleet it launched before that
  is only counted once its next turn ends and the reconcile finds it.
- **A fleet under a parked job is counted too**, by the same markers, filed under
  the background session instead of the pane — [parked jobs](#parked-jobs).
- **Subagents only.** Background shells, MCP tasks and monitors sit in the same
  registry and are deliberately left out; Claude's own footer already counts those
  ("6 shells, 2 monitors").
- **A nested agent** — one an agent spawned itself — is counted while it runs, but
  a reconcile may lose sight of it if the registry does not carry nested tasks, in
  which case the count runs short until that agent stops.

Which pane each session is judged by, in order: one actually running Claude, else
one in a window named `claude`, else the session's active pane. If the Claude in
that pane has parked its work on a background session, the row follows it — see
[parked jobs](#parked-jobs). Claude Code
reports its version as its process name (`2.1.223`), which is how it is
recognised — so a window auto-renamed away from `claude` is still found, and so
is Claude sitting in the half of a split that is not focused.

### Parked jobs

What is in a pane is not always what is doing the work. Handed something long,
Claude parks it: a background session starts under its daemon and the pane shows
that session instead. The daemon does not pass `$TMUX_PANE` on, so the session
actually working — spending the money, running the agents — has no pane to be
keyed by, and until this it exported nothing at all. The row then showed the
*other* session's last numbers, frozen at the moment it parked, which is not stale
by a little: it is the wrong session. One here read `8% $1.44` while its own status
line said `ctx 14% · $70.46`.

Claude keeps a registry that closes the gap, one small JSON file per running
session in `~/.claude/sessions`. The session in the pane carries a `parkedJobId`,
and the session doing the work carries the matching `jobId` beside its own session
id — which is the key its exports are filed under:

```
pane %92 → its session id → parkedJobId → jobId → sess-<id>.state / .meta / .agents
```

So both exporters now fall back to keying by session id when there is no pane, and
the monitor reads the registry once a tick into two flat indexes (bash 3.2 here has
no associative arrays) and follows that chain per pane. State, context, cost and
the agent count all come from whichever session the pane is really showing. A few
dozen one-line files read by bash itself, so it costs no forks.

Worth knowing:

- **The link needs the pane's own export to exist**, since that is where the
  session id comes from. The hook writes one from a session's first event, so this
  is only ever missing where the exporters are not installed.
- **A job that has exported nothing is not followed.** It has finished, or it runs
  where the exporters do not — and the pane's own numbers, old as they are, are
  then the best there is.
- **`active` totals the parked session, not the pane's.** One row, one session; the
  pane session's own spend is still in the ledger, so no day loses it.
- **A background session that never gets `SessionEnd`** leaves its `sess-*` files
  behind. They are a few hundred bytes and nothing reads them once the registry
  stops naming them; `rm ~/.claude/monitor/sess-*` while nothing is parked is the
  whole cleanup story.

### How the state is worked out

Two sources, because neither sees everything.

**The screen**, via `capture-pane`. What matters is not the wording but *where
Claude parked the cursor*, which says which widget has the keyboard: the input
box holds it after the prompt glyph, and a dialog moves it onto the selected row.
Wording alone will not separate them — "Do you want …" appears in Claude's own
replies and in the transcript of prompts already answered. The separator after
the glyph does: the input box uses a non-breaking space, every dialog a plain
one. Position does not, because the dialog `AskUserQuestion` puts up is not
indented and its selected row sits at column 0 looking exactly like an input box.

Text on the prompt row is not proof anyone typed it, either: Claude fills an
empty box with a dim suggestion of what to ask next. The cursor settles that too
— typing moves it past the glyph — and only in the ambiguous case is one extra
`capture-pane -pe` spent to check whether that text is dim.

**Claude's own events**, via `claude/monitor-hook.sh`, which every hook runs and
which leaves a state file per pane in `~/.claude/monitor`, plus the count of
subagents that pane has running — [counting subagents](#counting-subagents).
`claude/statusline.sh` adds context and cost to the same place, since neither is
on the screen at all. Both key their files by tmux server pid and pane id, which
is what `$TMUX_PANE` in their environment makes possible — or by session id where
there is no pane, which is how a [parked job](#parked-jobs) is found.

Neither source overrules the other:

- `NEEDS YOU` — whichever notices first. Usually the screen: `Notification` lags
  the prompt by about six seconds, a refresh tick is two.
- `draft` — the screen only. No event fires for typing.
- `working` / `idle` — the events, when fresh. They know a turn has started
  before any of it reaches the screen.
- `shell` / `other` / `gone` — the screen, and final.

A session with no exporter installed — another machine, or one started before it
was — loses the context and cost columns and nothing else. An exported state
older than `MONITOR_STALE` is ignored, so a Claude killed before `SessionEnd`
cannot leave a row stuck on `working`.

Notes:

- Everything is read by polling, so the monitor never attaches a client to the
  monitored sessions and cannot resize or disturb them.
- One `list-panes` covers every session. A tick over fifteen sessions costs
  ~100ms, and every session is sampled at the same instant.
- Claude Code UI strings live in `monitor_classify()` and `monitor_busy_titles()`
  in `tmux/monitor.sh` — the places to fix if a release reworks the footer or the
  title.
- Tunables: `MONITOR_INTERVAL` (seconds, default 2), `MONITOR_WINDOW` (preferred
  window name, default `claude`), `MONITOR_FILTER` (regex; list only matching
  sessions, e.g. `^graspen-`), `MONITOR_SESSION` (default `monitor`),
  `CLAUDE_MONITOR_DIR` (default `~/.claude/monitor`), `CLAUDE_SESSION_DIR`
  (Claude's own session registry, read to follow parked jobs, default
  `~/.claude/sessions`), `MONITOR_STALE` (seconds an exported state stays trusted,
  default 90), `CLAUDE_OVERAGE_AT` (window percentage counted as exhausted,
  default 100).
- `prefix + M` replaces tmux's default "clear marked pane"; `prefix + m` still
  toggles a mark.

## Claude Code config

`claude/` holds the Claude Code setup: settings, the two exporter scripts the
[session monitor](#session-monitor) reads, and user-level `skills/`. The scripts
and each skill are symlinked. Settings are **merged**, because Claude writes to
that file itself — `/model`, permission changes, enabled plugins — and a symlink
would drag every runtime toggle into git as a dirty working tree.

`claude/settings.json` holds **exactly two keys**: `statusLine` and `hooks`.
Those are what the session monitor reads, so they are the only things worth
sharing. Everything else in a Claude settings file belongs to whoever owns the
laptop and is never tracked:

| Shared, installed for everyone | Yours alone, never touched |
| --- | --- |
| `statusLine` | `editorMode`, `tui`, `model`, `enabledPlugins`, `extraKnownMarketplaces`, notifications |
| `hooks` | `env` and its tokens |
| | `permissions` — including `defaultMode` and the `skip*` prompts, which decide how much Claude does without asking |

The merge only touches the keys it is given, so `./install.sh` on a colleague's
machine gives them the monitor integration and changes nothing else. Their editor
mode, model and permission posture survive every `git pull && ./install.sh`.

The merge is `claude/merge-settings.sh`, runnable and testable on its own:

```bash
claude/merge-settings.sh <live.json> <shared.json>   # merged JSON on stdout
```

It refuses rather than damages — exit 1 on unreadable or invalid JSON, exit 2 if
the shared file has grown an `env` block — and `install.sh` writes through a temp
file, so a failure leaves the existing settings untouched.

The two shared keys are applied differently:

- **`statusLine` is replaced** — there is only one of it. If you already had a
  custom one, the install says so and leaves the previous file at
  `~/.claude/settings.json.bak`.
- **`hooks` are appended per event**, so a colleague's own `PostToolUse`
  formatter keeps running alongside ours. Entries pointing at our script are
  removed first, so re-running never stacks duplicates.

Paths inside are written as `~/.claude/…` rather than absolute, so the file is
portable between machines and between users. Both the status line and hooks run
their command through a shell, so the `~` expands.

`tests/unit/04-claude-settings-merge.test.sh` covers the merge. Its main
assertion is a property rather than a checklist: for every scalar leaf in the
original config, outside the two keys we own, the merged result must hold the
same value at the same path — which covers settings this repo has never heard of.
It runs over a config containing something of everything, over the empty and
near-empty cases, over this machine's real config if there is one, and three
times in a row to prove the result converges. The detector itself is tested
first, against a deliberately lossy pair, because "reports nothing lost" and
"is broken" look identical from the outside.

`tests/unit/03-no-secrets.test.sh` is the other backstop. It scans tracked and
new-but-unignored files for credential-shaped tokens and for secret-named JSON
keys with values, and it asserts the shared settings file contains nothing but
`statusLine` and `hooks` — an allowlist, so widening what this repo pushes onto
other laptops takes a deliberate edit to the test as well. The untracked half of
the scan matters most: a secret is at its most dangerous in the moment before it
is first committed.

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
3. Run `./test.sh --unit` — it will refuse anything carrying a credential
4. Commit and push

Use `link` for step 2: it backs up whatever is already at the destination, and
replaces an existing directory rather than creating the symlink inside it.

## Keeping in sync

```bash
git pull && ./install.sh
```
