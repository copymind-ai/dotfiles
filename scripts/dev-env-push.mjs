#!/usr/bin/env node
// Bulk-push entries from .env.local to Vercel's development environment.
// All vars are written as non-sensitive (plaintext) so they're readable later.
// Existing keys are skipped unless --force replaces them.
//
// Usage: dev env push [--force]

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";
import { createInterface } from "node:readline";
import { resolveProject, vercelApi } from "./dev-env.helpers.mjs";

const args = process.argv.slice(2);

if (args.includes("-h") || args.includes("--help")) {
  process.stdout.write(
    [
      "Usage: dev env push [--force]",
      "",
      "Bulk-push entries from .env.local to Vercel's development environment.",
      "Existing keys are skipped unless replaced.",
      "",
      "Flags:",
      "  --force     Replace keys that already exist on Vercel (default: skip them)",
      "  -h, --help  Show this help",
      "",
    ].join("\n"),
  );
  process.exit(0);
}

const force = args.includes("--force");

// --- Verify Vercel CLI is installed and authed (preflight) ---
// resolveProject() / resolveAuth() will fail if the project isn't linked
// or the auth file is missing, but these two checks give friendlier
// messages for the CLI install / login cases.
try {
  execSync("which vercel", { stdio: "ignore" });
} catch {
  console.error("Error: vercel CLI not found. Install with: npm i -g vercel");
  process.exit(1);
}
try {
  execSync("vercel whoami", { stdio: "ignore" });
} catch {
  console.error("Error: not logged in to Vercel. Run: vercel login");
  process.exit(1);
}

// --- Resolve worktree root + project ---
let root, projectId;
try {
  ({ root, projectId } = resolveProject());
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(1);
}
const localPath = path.join(root, ".env.local");
if (!existsSync(localPath)) {
  console.error(`Error: ${localPath} not found — nothing to push`);
  process.exit(1);
}

// --- Parse .env.local ---
// Minimal escape handling: only \" and \\ inside double-quotes are unescaped.
// \n is preserved as the literal two chars (matches the codebase's
// `.replace(/\\n/g, "\n")` convention for keys like GOOGLE_DRIVE_SA_PRIVATE_KEY).
function parseEnvFile(text) {
  const result = {};
  let pos = 0;
  while (pos < text.length) {
    // Skip whitespace and comment lines
    while (pos < text.length) {
      const c = text[pos];
      if (c === "\n" || c === " " || c === "\t" || c === "\r") {
        pos++;
      } else if (c === "#") {
        while (pos < text.length && text[pos] !== "\n") pos++;
      } else {
        break;
      }
    }
    if (pos >= text.length) break;

    const m = text.slice(pos).match(/^(?:export\s+)?([A-Z_][A-Z0-9_]*)=/);
    if (!m) {
      while (pos < text.length && text[pos] !== "\n") pos++;
      continue;
    }
    const key = m[1];
    pos += m[0].length;

    let value = "";
    if (pos < text.length && (text[pos] === '"' || text[pos] === "'")) {
      const quote = text[pos];
      pos++;
      while (pos < text.length && text[pos] !== quote) {
        if (quote === '"' && text[pos] === "\\" && pos + 1 < text.length) {
          const nxt = text[pos + 1];
          if (nxt === '"' || nxt === "\\") {
            value += nxt;
            pos += 2;
          } else {
            // Preserve unknown escape sequences verbatim (e.g. \n, \t)
            value += text[pos] + text[pos + 1];
            pos += 2;
          }
        } else {
          value += text[pos];
          pos++;
        }
      }
      if (pos < text.length) pos++;
    } else {
      const end = text.indexOf("\n", pos);
      const lineEnd = end === -1 ? text.length : end;
      let raw = text.slice(pos, lineEnd);
      raw = raw.replace(/\s+#[^\n]*$/, "").trimEnd();
      value = raw;
      pos = lineEnd;
    }

    result[key] = value;
  }
  return result;
}

const envText = readFileSync(localPath, "utf8");
const localEnv = parseEnvFile(envText);
const allKeys = Object.keys(localEnv).sort();

// Skip Vercel-system vars (VERCEL_*) — these are auto-injected by Vercel
// at runtime; pushing them as static values would override the dynamic
// behavior. VERCEL_OIDC_TOKEN, VERCEL_URL, VERCEL_ENV, etc. all qualify.
const SKIPPED_PREFIXES = ["VERCEL_"];
const skippedSystem = allKeys.filter((k) =>
  SKIPPED_PREFIXES.some((p) => k.startsWith(p)),
);
const skippedEmpty = allKeys.filter(
  (k) => localEnv[k] === "" && !skippedSystem.includes(k),
);
const keys = allKeys.filter(
  (k) => localEnv[k] !== "" && !skippedSystem.includes(k),
);

if (allKeys.length === 0) {
  console.log("No keys parsed from .env.local — nothing to push");
  process.exit(0);
}
if (skippedEmpty.length > 0) {
  console.log(`Skipping ${skippedEmpty.length} key(s) with empty values.`);
}
if (skippedSystem.length > 0) {
  console.log(
    `Skipping ${skippedSystem.length} Vercel-system key(s): ${skippedSystem.join(", ")}`,
  );
}

// --- Get existing development env keys via REST API ---
// (vercel env ls --json isn't supported on every CLI version, so go direct.)
console.log("Fetching existing Vercel development env...");
const allEnvs =
  (await vercelApi("GET", `/v10/projects/${projectId}/env`)).envs || [];
const existingKeys = new Set(
  allEnvs
    .filter((e) => (e.target || []).includes("development"))
    .map((e) => e.key),
);
const existingIdsByKey = new Map(
  allEnvs
    .filter((e) => (e.target || []).includes("development"))
    .map((e) => [e.key, e.id]),
);
console.log(`Found ${existingKeys.size} existing keys.\n`);

// --- Plan ---
const toAdd = keys.filter((k) => !existingKeys.has(k));
const existing = keys.filter((k) => existingKeys.has(k));
const replacing = force ? existing : [];
const skipping = force ? [] : existing;

console.log(`Push plan (target: development):`);
console.log(`  ${toAdd.length} new`);
console.log(`  ${replacing.length} replacing existing${force ? "" : ""}`);
console.log(
  `  ${skipping.length} skipping (already set; use --force to replace)`,
);
console.log("");

if (toAdd.length + replacing.length === 0) {
  console.log("Nothing to do.");
  process.exit(0);
}

// --- Confirm ---
const rl = createInterface({ input: process.stdin, output: process.stdout });
const answer = await new Promise((r) => rl.question("Proceed? [y/N] ", r));
rl.close();
if (!/^y(es)?$/i.test(answer.trim())) {
  console.log("Aborted.");
  process.exit(0);
}

// --- Execute via REST API ---
// `vercel env add` is interactive and on this CLI version is also intercepted
// by the Vercel Claude Code plugin, so use the API directly. POST to
// /v10/projects/{id}/env with type=plain so values are readable later.
async function vercelEnvAdd(key, value) {
  await vercelApi("POST", `/v10/projects/${projectId}/env`, {
    key,
    value,
    type: "plain",
    target: ["development"],
  });
}

async function vercelEnvDelete(id) {
  await vercelApi("DELETE", `/v10/projects/${projectId}/env/${id}`);
}

const targets = [...toAdd, ...replacing];
let added = 0,
  replaced = 0,
  failed = 0;
for (const key of targets) {
  const wasExisting = existingKeys.has(key);
  const value = localEnv[key];
  try {
    if (wasExisting) {
      const id = existingIdsByKey.get(key);
      if (id) await vercelEnvDelete(id);
    }
    await vercelEnvAdd(key, value);
    if (wasExisting) replaced++;
    else added++;
    console.log(`  ✓ ${key}`);
  } catch (err) {
    failed++;
    console.error(`  ✗ ${key}: ${err.message.split("\n")[0]}`);
  }
}

console.log("");
console.log(
  `Done. Added ${added}, replaced ${replaced}, failed ${failed}, skipped ${skipping.length}`,
);
if (failed > 0) process.exit(1);
