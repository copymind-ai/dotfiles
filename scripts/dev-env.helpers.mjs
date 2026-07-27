#!/usr/bin/env node
// Shared Vercel REST API helpers for the `dev env` tooling.
//
// Library exports (imported by sibling .mjs scripts):
//   resolveProject()                        → { projectId, teamId, root }
//   resolveAuth()                           → { token, authPath }
//   vercelApi(method, pathSuffix, body?)    → parsed JSON | {} (throws on non-2xx)
//   vercelEnvExists(name, target)           → boolean
//   vercelEnvAdd(name, target, value, opts) → void
//
// CLI dispatch (invoked as `node dev-env.helpers.mjs <op> ...` from bash):
//   exists <NAME> <TARGET>   exit 0 if found, 1 if not, 2 on error
//   add    <NAME> <TARGET>   value from VAR_VALUE env, SENSITIVE=1 for sensitive
//                            exit 0 on success, 1 on failure
//
// Why a single file: the two former helpers (dev-env-add-vercel.mjs,
// dev-env-vercel-exists.mjs) plus dev-env-push.mjs all duplicated the
// same auth + project + fetch boilerplate. Consolidating here lets
// callable scripts import the shared plumbing while bash callers still
// get a CLI surface.

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";

const VALID_TARGETS = ["production", "preview", "development"];

export function resolveProject() {
  let root;
  try {
    root = execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
    }).trim();
  } catch {
    throw new Error("not inside a git worktree");
  }
  const projectFile = path.join(root, ".vercel/project.json");
  if (!existsSync(projectFile)) {
    throw new Error(`${projectFile} not found. Run: vercel link`);
  }
  const project = JSON.parse(readFileSync(projectFile, "utf8"));
  return { projectId: project.projectId, teamId: project.orgId, root };
}

export function resolveAuth() {
  const candidates = [
    path.join(
      process.env.HOME,
      "Library/Application Support/com.vercel.cli/auth.json",
    ), // macOS
    path.join(process.env.HOME, ".local/share/com.vercel.cli/auth.json"), // Linux
    path.join(process.env.HOME, ".config/com.vercel.cli/auth.json"), // alt Linux
  ];
  const authPath = candidates.find((p) => existsSync(p));
  if (!authPath) {
    throw new Error("Vercel auth file not found. Run: vercel login");
  }
  const token = JSON.parse(readFileSync(authPath, "utf8")).token;
  if (!token) throw new Error(`no token in ${authPath}. Run: vercel login`);
  return { token, authPath };
}

// Lazy-resolve project + auth once per process so library callers
// don't pay for it on import and CLI mode doesn't double-resolve.
let _ctx;
function ctx() {
  if (!_ctx) {
    const { projectId, teamId } = resolveProject();
    const { token } = resolveAuth();
    _ctx = { projectId, teamId, token };
  }
  return _ctx;
}

export async function vercelApi(method, pathSuffix, body) {
  const { teamId, token } = ctx();
  const sep = pathSuffix.includes("?") ? "&" : "?";
  const tq = teamId ? `${sep}teamId=${teamId}` : "";
  const url = `https://api.vercel.com${pathSuffix}${tq}`;
  const init = { method, headers: { Authorization: `Bearer ${token}` } };
  if (body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetch(url, init);
  const text = await res.text();
  if (!res.ok) {
    let msg = text;
    try {
      msg = JSON.parse(text)?.error?.message || text;
    } catch {
      /* keep raw text */
    }
    throw new Error(`HTTP ${res.status}: ${msg}`);
  }
  return text ? JSON.parse(text) : {};
}

export async function vercelEnvExists(name, target) {
  const { projectId } = ctx();
  const json = await vercelApi("GET", `/v10/projects/${projectId}/env`);
  return (json.envs || []).some(
    (e) => e.key === name && (e.target || []).includes(target),
  );
}

export async function vercelEnvAdd(
  name,
  target,
  value,
  { sensitive = false } = {},
) {
  const { projectId } = ctx();
  const body = {
    key: name,
    value,
    type: sensitive ? "sensitive" : "plain",
    target: [target],
  };
  // For preview, omitting gitBranch (or null) means "all Preview branches".
  if (target === "preview") body.gitBranch = null;
  await vercelApi("POST", `/v10/projects/${projectId}/env`, body);
}

// --- CLI dispatch ---
// Run the dispatcher only when this file is the entrypoint, not when
// imported as a module by a sibling script.
const isCli = import.meta.url === `file://${process.argv[1]}`;
if (isCli) {
  const [op, name, target] = process.argv.slice(2);
  const usage =
    "Usage: dev-env.helpers.mjs <exists|add> <NAME> <TARGET>\n" +
    "  add: requires VAR_VALUE env var; SENSITIVE=1 marks the var sensitive.";

  if (!op || !name || !target) {
    console.error(usage);
    process.exit(2);
  }
  if (!VALID_TARGETS.includes(target)) {
    console.error(`Invalid target: ${target}`);
    process.exit(op === "exists" ? 2 : 1);
  }

  try {
    if (op === "exists") {
      const found = await vercelEnvExists(name, target);
      process.exit(found ? 0 : 1);
    } else if (op === "add") {
      const value = process.env.VAR_VALUE;
      if (value === undefined) {
        console.error("Requires VAR_VALUE env var.");
        process.exit(1);
      }
      await vercelEnvAdd(name, target, value, {
        sensitive: process.env.SENSITIVE === "1",
      });
      process.exit(0);
    } else {
      console.error(usage);
      process.exit(2);
    }
  } catch (err) {
    console.error(err.message);
    process.exit(op === "exists" ? 2 : 1);
  }
}
