#!/usr/bin/env node
// Add or update a single Vercel env var via the REST API. Bypasses
// `vercel env add`'s interactive prompts (the value prompt and the
// preview-only "Add to which Git branch?" prompt — see vercel/vercel#15763).
//
// Usage: dev-env-add-vercel.helpers.mjs <NAME> <TARGET>
//   - VAR_VALUE env var supplies the value (via env var so it doesn't
//     appear in `ps` and isn't mangled by shell quoting).
//   - SENSITIVE=1 marks the var as sensitive (default: plain/non-sensitive).
//
// On success: silent exit 0.
// On failure: prints HTTP status + Vercel's error message to stderr, exit 1.

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";

const [name, target] = process.argv.slice(2);
const value = process.env.VAR_VALUE;
const sensitive = process.env.SENSITIVE === "1";

if (!name || !target || value === undefined) {
  console.error("Usage: dev-env-add-vercel.helpers.mjs <NAME> <TARGET>");
  console.error("Requires VAR_VALUE env var.");
  process.exit(1);
}
if (!["production", "preview", "development"].includes(target)) {
  console.error(`Invalid target: ${target}`);
  process.exit(1);
}

// --- Resolve project + auth ---
const root = execSync("git rev-parse --show-toplevel", {
  encoding: "utf8",
}).trim();
const projectFile = path.join(root, ".vercel/project.json");
if (!existsSync(projectFile)) {
  console.error(`Error: ${projectFile} not found. Run: vercel link`);
  process.exit(1);
}
const project = JSON.parse(readFileSync(projectFile, "utf8"));
const projectId = project.projectId;
const teamId = project.orgId;

const authCandidates = [
  path.join(
    process.env.HOME,
    "Library/Application Support/com.vercel.cli/auth.json",
  ), // macOS
  path.join(process.env.HOME, ".local/share/com.vercel.cli/auth.json"), // Linux
  path.join(process.env.HOME, ".config/com.vercel.cli/auth.json"), // alt Linux
];
const authPath = authCandidates.find((p) => existsSync(p));
if (!authPath) {
  console.error("Error: Vercel auth file not found. Run: vercel login");
  process.exit(1);
}
const auth = JSON.parse(readFileSync(authPath, "utf8"));
const token = auth.token;
if (!token) {
  console.error(`Error: no token in ${authPath}. Run: vercel login`);
  process.exit(1);
}

// --- Make the API call ---
const queryParams = teamId ? `?teamId=${teamId}` : "";
const url = `https://api.vercel.com/v10/projects/${projectId}/env${queryParams}`;
const body = {
  key: name,
  value,
  type: sensitive ? "sensitive" : "plain",
  target: [target],
};
// For preview, omitting gitBranch (or null) means "all Preview branches"
if (target === "preview") body.gitBranch = null;

const res = await fetch(url, {
  method: "POST",
  headers: {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify(body),
});

if (res.ok) process.exit(0);

const text = await res.text();
let errMsg = text;
try {
  const json = JSON.parse(text);
  errMsg = json?.error?.message || text;
} catch {
  /* keep raw text */
}
console.error(`HTTP ${res.status}: ${errMsg}`);
process.exit(1);
