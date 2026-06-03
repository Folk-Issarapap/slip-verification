#!/usr/bin/env node
/**
 * render-wrangler.mjs — local deploy wrapper for Bro Pay apps.
 *
 * Usage:
 *   node scripts/render-wrangler.mjs <app> <env> [--dry-run]
 *
 *   app  ∈ {api, admin, merchant, checkout, reseller}
 *   env  ∈ {production, staging}
 *
 * What it does:
 *   1. Loads .env.<env> from the repo root (KEY=VALUE, no dotenv dep).
 *   2. Reads apps/<app>/wrangler.jsonc.
 *   3. Substitutes every ${VAR} with the value from the env file.
 *   4. Fails loudly if any ${VAR} remains after substitution.
 *   5. For frontends (non-api) in non-production env: swaps the top-level
 *      "name" to env.<env>.name — working around the vinext --env bug where
 *      staging deploys land on the production worker.
 *   6. For frontends: sets process.env.NEXT_PUBLIC_API_URL from the env map
 *      so vinext bakes the correct API URL into the bundle.
 *   7. Writes the rendered wrangler.jsonc in place (vinext has no --config flag).
 *   8. Spawns the deploy command; always restores the original on exit.
 *   --dry-run: performs steps 1–7 (writes the rendered file) then restores
 *      without spawning the deploy command. Useful for CI validation.
 *
 * Signal/error handlers installed before file mutation restore the original
 * synchronously so a Ctrl-C mid-deploy doesn't leave a polluted wrangler.jsonc.
 *
 * Deploy commands:
 *   api       → pnpm exec wrangler deploy [--env <env>]  (cwd: apps/api)
 *   frontends → pnpm exec vinext deploy                  (cwd: apps/<app>)
 */

import { spawnSync } from "node:child_process"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

// ── Constants ──────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, "..")

const VALID_APPS = ["api", "admin", "merchant", "checkout", "reseller"]
const VALID_ENVS = ["production", "staging"]
const FRONTEND_APPS = ["admin", "merchant", "checkout", "reseller"]

// ── Argument parsing ───────────────────────────────────────────────────────

const args = process.argv.slice(2)
const dryRun = args.includes("--dry-run")
const positional = args.filter((a) => !a.startsWith("--"))

const [appName, envName] = positional

if (!appName || !envName) {
  console.error("Usage: node scripts/render-wrangler.mjs <app> <env> [--dry-run]")
  console.error(`  app ∈ {${VALID_APPS.join(", ")}}`)
  console.error(`  env ∈ {${VALID_ENVS.join(", ")}}`)
  process.exit(2)
}

if (!VALID_APPS.includes(appName)) {
  console.error(`Unknown app: "${appName}". Valid: ${VALID_APPS.join(", ")}`)
  process.exit(2)
}

if (!VALID_ENVS.includes(envName)) {
  console.error(`Unknown env: "${envName}". Valid: ${VALID_ENVS.join(", ")}`)
  process.exit(2)
}

// ── Env-file parser ────────────────────────────────────────────────────────

/**
 * Parse a .env-style file into a Map<string, string>.
 * Rules:
 *   - Lines starting with # (ignoring leading whitespace) are comments.
 *   - Blank lines are skipped.
 *   - Values split on the FIRST "=" only (values may contain "=").
 *   - Keys are whitespace-trimmed.
 *   - Values: if wrapped in matching " or ' quotes, those outer quotes are
 *     stripped and the inner content preserved verbatim. Unquoted values are
 *     whitespace-trimmed. Inline "#" is NOT treated as a comment — env values
 *     may legitimately contain "#" (e.g. hex colors, URL fragments).
 *   - Empty value (KEY=) → empty string.
 *   - We do NOT touch process.env — callers inject selectively.
 */
function parseEnvFile(filePath) {
  const raw = readFileSync(filePath, "utf-8")
  const map = new Map()
  for (const line of raw.split("\n")) {
    const trimmed = line.trimStart()
    // Skip comments and blanks
    if (trimmed.startsWith("#") || trimmed === "") continue
    const eqIdx = trimmed.indexOf("=")
    if (eqIdx === -1) continue // no "=" → not a valid KV line
    const key = trimmed.slice(0, eqIdx).trimEnd()
    if (!key) continue
    const rawValue = trimmed.slice(eqIdx + 1)
    const value = stripOuterQuotes(rawValue)
    map.set(key, value)
  }
  return map
}

/**
 * Strip matching outer " or ' quotes. Only strips if the value starts and
 * ends with the same quote character. Unquoted values are trimmed of
 * surrounding whitespace.
 */
function stripOuterQuotes(raw) {
  const t = raw // do not trim before quote check (quoted values can have outer space)
  if (
    (t.startsWith('"') && t.trimEnd().endsWith('"')) ||
    (t.startsWith("'") && t.trimEnd().endsWith("'"))
  ) {
    const inner = t.trimEnd()
    return inner.slice(1, -1)
  }
  return raw.trim()
}

// ── JSONC comment stripper (verbatim from deploy-env.mjs) ─────────────────

/**
 * Strip JSONC block comments and line comments.
 * The [^:\\] guard prevents stripping "://" inside string values.
 */
function stripJsonc(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^[\s]*\/\/.*$/gm, "")
    .replace(/([^:\\])\/\/.*$/gm, "$1")
}

// ── Load env file ──────────────────────────────────────────────────────────

const envFilePath = path.join(REPO_ROOT, `.env.${envName}`)
if (!existsSync(envFilePath)) {
  console.error(`Missing env file: ${envFilePath}`)
  console.error(`Create it with the required variables and try again.`)
  process.exit(1)
}

const envMap = parseEnvFile(envFilePath)
console.log(`\nLoaded ${envMap.size} variable(s) from ${envFilePath}`)

// ── Read wrangler.jsonc ────────────────────────────────────────────────────

const appDir = path.join(REPO_ROOT, "apps", appName)
const wranglerPath = path.join(appDir, "wrangler.jsonc")

if (!existsSync(wranglerPath)) {
  console.error(`wrangler.jsonc not found at: ${wranglerPath}`)
  process.exit(1)
}

const original = readFileSync(wranglerPath, "utf-8")

// ── Substitute ${VAR} placeholders ────────────────────────────────────────

let rendered = original.replace(/\$\{(\w+)\}/g, (match, varName) => {
  return envMap.has(varName) ? envMap.get(varName) : match
})

// Fail loud: any remaining ${VAR} means a required variable is absent.
// Scan only the JSON content (comments stripped) to avoid false-positives from
// documentation text like "All ${VAR} below are rendered at deploy time".
const remaining = [...stripJsonc(rendered).matchAll(/\$\{(\w+)\}/g)].map((m) => m[1])
if (remaining.length > 0) {
  const unique = [...new Set(remaining)].sort()
  console.error(`\nMissing variables — substitution incomplete. Add these to ${envFilePath}:`)
  for (const v of unique) {
    console.error(`  ${v}`)
  }
  process.exit(1)
}

// ── Frontend: swap top-level "name" for non-production envs ───────────────
//
// vinext 0.0.39 bug: `--env <name>` is passed to wrangler but the redirected
// dist/server/wrangler.json strips the env block. Wrangler falls back to the
// top-level worker name, so staging lands on the production worker.
// Fix: rewrite top-level "name" before invoking vinext so it targets the
// correct worker directly.

const isFrontend = FRONTEND_APPS.includes(appName)

if (isFrontend && envName !== "production") {
  const parsed = JSON.parse(stripJsonc(rendered))
  const topLevelName = parsed.name
  if (!topLevelName) {
    console.error('Could not find top-level "name" in wrangler.jsonc after substitution.')
    process.exit(1)
  }
  const targetName = parsed.env?.[envName]?.name
  if (!targetName) {
    console.error(`wrangler.jsonc has no env.${envName}.name — define it or pick another env`)
    process.exit(1)
  }

  // Replace only the first occurrence of the top-level name value.
  const namePattern = new RegExp(
    `"name"\\s*:\\s*"${topLevelName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`
  )
  const patched = rendered.replace(namePattern, `"name": "${targetName}"`)
  if (patched === rendered) {
    console.error('Failed to patch top-level "name" — pattern did not match. Aborting.')
    process.exit(1)
  }
  rendered = patched
  console.log(`\nWorker name: ${targetName}  (vinext env bug workaround; was: ${topLevelName})`)
}

// ── Frontend: inject NEXT_PUBLIC_API_URL ───────────────────────────────────
//
// vinext bakes this at build time. If it's absent the bundle gets an empty
// API URL and all API calls fail silently. Require it explicitly.

if (isFrontend) {
  const apiUrl = envMap.get("NEXT_PUBLIC_API_URL")
  if (!apiUrl) {
    console.error(`\nNEXT_PUBLIC_API_URL is not defined in ${envFilePath}`)
    console.error("Add it — vinext bakes this into the bundle and it must be set before deploy.")
    process.exit(1)
  }
  // Mutate process.env so the spawned vinext build inherits it.
  process.env.NEXT_PUBLIC_API_URL = apiUrl
  console.log(`NEXT_PUBLIC_API_URL = ${apiUrl}`)
}

// ── Build the deploy command ───────────────────────────────────────────────

let deployCmd
let deployArgs
let deployCwd

if (appName === "api") {
  deployCmd = "pnpm"
  deployArgs = ["exec", "wrangler", "deploy"]
  // wrangler handles --env correctly for the api; do not swap top-level name.
  // Use explicit env blocks when present so production can keep top-level config
  // local-dev friendly while deploys still get routes and non-inherited bindings.
  const parsed = JSON.parse(stripJsonc(rendered))
  if (parsed.env?.[envName]) {
    deployArgs.push("--env", envName)
  }
  deployCwd = appDir
} else {
  deployCmd = "pnpm"
  deployArgs = ["exec", "vinext", "deploy"]
  deployCwd = appDir
}

const resolvedWorkerName = (() => {
  try {
    const p = JSON.parse(stripJsonc(rendered))
    return p.env?.[envName]?.name ?? p.name ?? "(unknown)"
  } catch {
    return "(parse error)"
  }
})()

console.log(`\nApp:     ${appName}`)
console.log(`Env:     ${envName}`)
console.log(`Worker:  ${resolvedWorkerName}`)
console.log(`Command: ${[deployCmd, ...deployArgs].join(" ")}`)
console.log(`CWD:     ${deployCwd}`)
if (dryRun) {
  console.log("\n[dry-run] Skipping deploy — writing rendered file then restoring.\n")
}

// ── Signal / exit handlers — install BEFORE file mutation ─────────────────

let restored = false
const restore = () => {
  if (restored) return
  restored = true
  writeFileSync(wranglerPath, original)
}

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    restore()
    // Standard exit codes: SIGINT=130, SIGTERM=143, SIGHUP=129
    const code = sig === "SIGINT" ? 130 : sig === "SIGTERM" ? 143 : 129
    process.exit(code)
  })
}

process.on("uncaughtException", (err) => {
  restore()
  console.error("Uncaught exception:", err)
  process.exit(1)
})

process.on("unhandledRejection", (reason) => {
  restore()
  console.error("Unhandled rejection:", reason)
  process.exit(1)
})

// beforeExit fires when the event loop drains normally — belt-and-suspenders
// restore for non-signal exits that somehow bypass the try/finally.
process.on("beforeExit", restore)

// ── Mutate + deploy ────────────────────────────────────────────────────────

let exitCode = 1
try {
  writeFileSync(wranglerPath, rendered)
  console.log(`\nwrangler.jsonc rendered — starting deploy...\n`)

  if (dryRun) {
    console.log("[dry-run] Deploy skipped. Rendered file will be restored now.")
    exitCode = 0
  } else {
    const result = spawnSync(deployCmd, deployArgs, {
      cwd: deployCwd,
      stdio: "inherit",
      env: process.env,
    })
    exitCode = result.status ?? 1
  }
} finally {
  restore()
  console.log("\nwrangler.jsonc restored to original.")
}

process.exit(exitCode)
