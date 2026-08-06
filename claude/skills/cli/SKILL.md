---
name: "cli"
description: "Builder onboarding and first integration with Customer.io — signup, sandbox testing, test recipients, SDK/app wiring, backend transactional sends, billing activation checks, and going live."
---

# Customer.io CLI (`cio`)

Customer.io ships an agent-first CLI, `cio`. Before working on anything in
Customer.io — Journeys, CDP Pipelines, Design Studio, transactional messaging,
onboarding, or debugging `fly.customer.io` / `cdp.customer.io` — run:

```bash
cio prime
```

`cio prime` prints the full, current instructions: JSON output rules, the
`cio api` command, schema introspection (`cio schema`), how to read
task-specific skills (`cio skills read <skill>`), global flags, exit codes,
and examples. Follow what it returns.

If `cio` is not installed, see https://github.com/customerio/cli.
