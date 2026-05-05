#!/usr/bin/env node
// Bulk-push entries from .env.local to Vercel's development environment.
// All vars are written as non-sensitive (plaintext) so they're readable later.
// Existing keys are skipped unless --force replaces them.
//
// Usage: dev env push [--force]

import { existsSync, readFileSync } from "node:fs";
import { execSync, spawn } from "node:child_process";
import path from "node:path";
import { createInterface } from "node:readline";

const args = process.argv.slice(2);
const force = args.includes("--force");

// --- Resolve worktree root ---
let root;
try {
  root = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
} catch {
  console.error("Error: not inside a git worktree");
  process.exit(1);
}
const localPath = path.join(root, ".env.local");
if (!existsSync(path.join(root, ".env.example"))) {
  console.error("Error: .env.example not found at worktree root");
  process.exit(1);
}
if (!existsSync(localPath)) {
  console.error(`Error: ${localPath} not found — nothing to push`);
  process.exit(1);
}

// --- Verify Vercel auth ---
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
if (!existsSync(path.join(root, ".vercel/project.json"))) {
  console.error(
    `Error: Vercel project not linked. Run: vercel link (from ${root})`,
  );
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
const keys = allKeys.filter((k) => localEnv[k] !== "");

if (allKeys.length === 0) {
  console.log("No keys parsed from .env.local — nothing to push");
  process.exit(0);
}
if (keys.length < allKeys.length) {
  const empty = allKeys.length - keys.length;
  console.log(`Skipping ${empty} key(s) with empty values.`);
}

// --- Get existing development env keys ---
console.log("Fetching existing Vercel development env...");
let existingKeys = new Set();
try {
  const json = execSync("vercel env ls development --json", {
    encoding: "utf8",
  });
  const parsed = JSON.parse(json);
  const envs = Array.isArray(parsed) ? parsed : parsed.envs || [];
  existingKeys = new Set(envs.map((e) => e.key));
  console.log(`Found ${existingKeys.size} existing keys.\n`);
} catch (err) {
  console.error(
    "Warning: could not fetch existing Vercel env list — will attempt all pushes.",
  );
  console.error(err.message);
}

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

// --- Execute ---
async function vercelEnvAdd(key, value) {
  return new Promise((resolve, reject) => {
    const proc = spawn("vercel", ["env", "add", key, "development"], {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    proc.stderr.on("data", (d) => (stderr += d.toString()));
    proc.stdin.write(value);
    proc.stdin.end();
    proc.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(stderr.trim() || `exit ${code}`)),
    );
  });
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
      try {
        execSync(`vercel env rm ${key} development -y`, { stdio: "ignore" });
      } catch {
        /* ignore — proceed to add */
      }
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
