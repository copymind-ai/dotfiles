# Tests

Three-layer test suite against a real bare repo + Supabase container.

## Prerequisites

- `git`, `supabase` CLI, `docker`, `jq`
- Docker daemon running

## Running

```bash
./test.sh                    # all layers
./test.sh --unit             # unit only (no Supabase needed)
./test.sh --integration      # integration only
./test.sh --e2e              # e2e only
./test.sh link               # pattern filter across all layers
```

Uses test project `test-int` on ports 54421/54422.

## Layers

### Unit (`tests/unit/`)
Pure functions and routers — no Supabase, no worktree state needed.

| File | What it tests |
|------|--------------|
| `01-pure-functions` | Sanitization, port alloc, upsert_env, classify_var, migration helpers |
| `02-routers` | Command dispatch, usage output, non-bare repo checks, missing args |

### Integration (`tests/integration/`)
Single commands tested in dependency order. Each test builds on state from previous tests.

| # | File | What it tests |
|---|------|--------------|
| 1 | `01-worktree-up-no-supabase` | `dev wt up` when Supabase is down — hints shown |
| 2 | `02-supabase-up` | `dev sb up` — creates worktree, starts Supabase, idempotent |
| 3 | `03-supabase-status` | `dev sb status` — shows running status |
| 4 | `04-worktree-env` | `dev wt env` — Supabase var injection, COPYMIND_API_HOST |
| 5 | `05-worktree-up-with-supabase` | `dev wt up` when Supabase is running — auto-injects vars |

### E2E (`tests/e2e/`)
Multi-command developer workflows.

| File | What it tests |
|------|--------------|
| `01-migration-lifecycle` | link → idempotent → multi-wt → timestamp conflict → unlink → merge-to-main → teardown → cleanup |
