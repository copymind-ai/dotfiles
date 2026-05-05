#!/usr/bin/env node
// Check whether a Vercel env var exists for a given target via the REST API.
// Bypasses `vercel env ls`, which on some CLI versions doesn't support
// --json (returns "unknown or unexpected option") and on others filters out
// encrypted/sensitive entries — both make existence checks unreliable.
//
// Usage: dev-env-vercel-exists.mjs <NAME> <TARGET>
// Exit:  0 if exists in target, 1 if not, 2 on error.

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";

const [name, target] = process.argv.slice(2);

if (!name || !target) {
  console.error("Usage: dev-env-vercel-exists.mjs <NAME> <TARGET>");
  process.exit(2);
}

const root = execSync("git rev-parse --show-toplevel", {
  encoding: "utf8",
}).trim();
const projectFile = path.join(root, ".vercel/project.json");
if (!existsSync(projectFile)) {
  console.error(`Error: ${projectFile} not found. Run: vercel link`);
  process.exit(2);
}
const project = JSON.parse(readFileSync(projectFile, "utf8"));
const projectId = project.projectId;
const teamId = project.orgId;

const authCandidates = [
  path.join(
    process.env.HOME,
    "Library/Application Support/com.vercel.cli/auth.json",
  ),
  path.join(process.env.HOME, ".local/share/com.vercel.cli/auth.json"),
  path.join(process.env.HOME, ".config/com.vercel.cli/auth.json"),
];
const authPath = authCandidates.find((p) => existsSync(p));
if (!authPath) {
  console.error("Error: Vercel auth file not found. Run: vercel login");
  process.exit(2);
}
const token = JSON.parse(readFileSync(authPath, "utf8")).token;

const queryParams = teamId ? `?teamId=${teamId}` : "";
const url = `https://api.vercel.com/v10/projects/${projectId}/env${queryParams}`;
const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
if (!res.ok) {
  console.error(`HTTP ${res.status}: ${await res.text()}`);
  process.exit(2);
}
const json = await res.json();
const envs = json.envs || [];
const found = envs.some(
  (e) => e.key === name && (e.target || []).includes(target),
);
process.exit(found ? 0 : 1);
