# Tests

Three-layer test suite against a real bare repo + Supabase container.

## Prerequisites

- Run `./install.sh` from the repo root to install `supabase`, `jq`, `pgflow`, `node`, etc.
- Plus `psql`, `rsync`, `curl`, `docker`
- Docker daemon running

## Running

```bash
./test.sh                    # all layers
./test.sh --unit             # unit only (no Supabase needed)
./test.sh --integration      # integration only
./test.sh --e2e              # e2e only
./test.sh link               # pattern filter across all layers
```

Uses test project `test-int` on ports 54621/54622 (follows `+100` per-project pattern: `54321`=app, `54421`=admin, `54521`=marketing, `54621`=dotfiles test).

## Layers

### Unit (`tests/unit/`)

Pure functions and routers — no Supabase, no worktree state needed.

| File                        | What it tests                                                                   |
| --------------------------- | ------------------------------------------------------------------------------- |
| `01-pure-functions`         | Sanitization, port alloc, upsert_env, classify_var, migration helpers           |
| `02-routers`                | Command dispatch, usage output, non-bare repo checks, missing args              |
| `12-do-migrate-up`          | Flatten/restore, db-port parsing, failure trap (stubbed `supabase`)             |
| `13-do-seed-up`             | Seed registry, users.sql skip, idempotence, rename-as-new (stubbed `psql`)      |
| `15-ensure-functions-serve` | Container/host split-brain detection, spawn vs no-op (stubbed `docker`/`pgrep`) |

### Integration (`tests/integration/`)

Single commands tested in dependency order. Each test builds on state from previous tests.

| #   | File                           | What it tests                                                   |
| --- | ------------------------------ | --------------------------------------------------------------- |
| 1   | `01-worktree-up-no-supabase`   | `dev wt up` when Supabase is down — hints shown                 |
| 2   | `02-supabase-up`               | `dev sb up` — creates worktree, starts Supabase, idempotent     |
| 3   | `03-supabase-status`           | `dev sb status` — shows running status                          |
| 4   | `04-worktree-env`              | `dev wt env` — Supabase var injection, COPYMIND_API_HOST        |
| 5   | `05-worktree-up-with-supabase` | `dev wt up` when Supabase is running — auto-injects vars        |
| 6   | `06-supabase-dispatch`         | `dev sb` dispatcher argument validation for new subcommands     |
| 7   | `07-worktree-port`             | `dev wt port` — regenerates override from registry, error paths |

### E2E (`tests/e2e/`)

Multi-command developer workflows.

| File                     | What it tests                                                                                      |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| `01-migration-lifecycle` | link → idempotent → multi-wt → timestamp conflict → unlink → merge-to-main → teardown → cleanup    |
| `02-db-migrate-seed`     | `dev sb migrate` + `dev sb seed` — no-op, new file, idempotence, users.sql skip, rename-as-new     |
| `03-db-reset`            | `dev sb reset` — wipe + re-migrate + re-seed, functions serve backgrounded, feature-worktree scope |
| `04-db-flow-lifecycle`   | `dev sb flow` released-flow guard fires (even when the stack was booted from a feature worktree)   |
