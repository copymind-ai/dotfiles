# Test plan: symlink-based migration hub

## Running the tests

The test script is fully self-contained — it creates a temporary bare git repo, starts Supabase, runs all 11 tests, and cleans up.

### Prerequisites

- `git`, `supabase` CLI, `docker`, `jq` installed
- Docker daemon running

### Run

```bash
./tests/test-migration-hub.sh
```

No need to stop your existing Supabase — the test uses its own project (`test-mh`) on separate ports (`54421`/`54422`) so both can run simultaneously.

### What it does

1. Creates a temporary bare repo at `/tmp/dotfiles-migration-hub-test-*`
2. Scaffolds a minimal project (config.toml, db-migrate-local.sh, docker-compose.yml, initial migration)
3. Starts an isolated Supabase instance (project: `test-mh`, ports: `54421`/`54422`)
4. Runs 11 test cases covering the full migration hub lifecycle
5. Stops the test Supabase and removes the temp directory

### Tests

| #   | Test                       | Commands tested       | Key assertion                               |
| --- | -------------------------- | --------------------- | ------------------------------------------- |
| 1   | Supabase wt setup          | `dev wt sb`           | Hub created, migrations applied, idempotent |
| 2   | Create feature wt          | `dev wt up`           | Hub refreshed, no symlinks                  |
| 3   | Migrate — no new           | `dev sb migrate`      | "No new migrations"                         |
| 4   | Migrate — new migration    | `dev sb migrate`      | Symlinked + applied to DB                   |
| 5   | Migrate — idempotent       | `dev sb migrate`      | Skips already-symlinked                     |
| 6   | Migrate — second migration | `dev sb migrate`      | Only new file symlinked                     |
| 7   | Multi-worktree coexistence | `dev wt up` + migrate | Both worktrees' symlinks coexist            |
| 8   | Timestamp conflict         | `dev sb migrate`      | Rejected with diagnostic, exit 1            |
| 9   | Teardown first wt          | `dev wt down`         | Only its symlinks removed, DB repaired      |
| 10  | Teardown second wt         | `dev wt down`         | All symlinks gone, DB clean                 |
| 11  | Post-cleanup sanity        | `dev sb migrate`      | Hub is clean, no-op                         |
