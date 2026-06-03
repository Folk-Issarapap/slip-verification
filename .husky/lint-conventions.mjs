#!/usr/bin/env node
// lint-conventions.mjs
//
// Fallback enforcement for canonical-chrome rules that Biome 2.4's GritQL plugin engine
// cannot yet handle. Biome 2.4's plugin/plugin rule loads .grit files but the pattern
// matcher is non-functional — it neither emits diagnostics nor transforms code. This
// script fills the gap by grepping staged or all tracked *.{ts,tsx} files for violations.
//
// Rules enforced:
//   1. no-card-className — Card primitive callers cannot pass custom className.
//      Use primitive props, composition, or dedicated wrappers such as DataGridCard or KpiStripCard.
//   2. no-datagrid-in-cardcontent — DataGrid belongs directly in DataGridCard, not
//      in padded CardContent.
//   3. no-datagrid-in-plain-card — DataGrid cards must use DataGridCard, not raw Card.
//   4. no-cardtitle-custom-children — CardTitle is title text only.
//   5. no-carddescription-in-cardaction — CardAction is for controls/badges, not descriptions.
//   6. no-cardheader-custom-child — CardHeader direct children must be Card primitives.
//   7. no-tailwind-v3-gradient — bg-gradient-to-* is Tailwind v3 syntax.
//      Use bg-linear-to-* for Tailwind v4.
//
// When Biome's GritQL matcher matures, remove this script and rely on the .grit files
// in .biome/plugins/ which already encode the same patterns.

import { execSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const args = process.argv.slice(2)
const CHECK_ALL = args.includes("--all")

function isTsFile(filePath) {
  return /\.(ts|tsx)$/.test(filePath)
}

function isEnforcedFile(filePath) {
  return isTsFile(filePath) && !filePath.startsWith(".biome/plugins/__fixtures__/")
}

function splitNullDelimited(output) {
  return output.split("\0").filter(Boolean)
}

function getTrackedFiles() {
  const tracked = execSync("git ls-files -z -- '*.ts' '*.tsx'", {
    encoding: "utf8",
  })
  return splitNullDelimited(tracked).filter(isEnforcedFile)
}

function getStagedFiles() {
  const staged = execSync("git diff --cached --name-only --diff-filter=ACMR", {
    encoding: "utf8",
  }).trim()
  if (!staged) return []
  return staged.split("\n").filter(isEnforcedFile)
}

// Default mode checks staged files for pre-commit speed.
// --all checks every tracked TS/TSX file so `pnpm lint` and CI catch convention drift.
// Passing one or more paths directly keeps manual testing simple.
let filesToCheck = []
if (CHECK_ALL) {
  filesToCheck = getTrackedFiles()
} else if (args.length > 0) {
  filesToCheck = args.filter((arg) => !arg.startsWith("-")).filter(isTsFile)
} else {
  filesToCheck = getStagedFiles()
}

if (filesToCheck.length === 0) process.exit(0)

const RULES = [
  {
    id: "no-card-className",
    // Match card primitive opening tags with any className prop, including multiline JSX attributes.
    pattern:
      /<(Card|DataGridCard|KpiStripCard|CardHeader|CardContent|CardFooter|CardTitle|CardDescription|CardAction)\b[^>]*\bclassName\s*=\s*(?:"[^"]*"|'[^']*'|\{[^{}]*\})/g,
    message:
      "Do not pass className to Card primitive components. Adjust spacing through the card composition APIs instead.",
  },
  {
    id: "no-datagrid-in-cardcontent",
    // Match DataGrid nested inside a CardContent block, including multiline JSX.
    pattern: /<CardContent\b[^>]*>(?:(?!<\/CardContent>).)*<DataGrid\b/gs,
    message:
      "Do not place DataGrid inside CardContent. Use DataGridCard and render DataGrid as a direct full-bleed child.",
  },
  {
    id: "no-datagrid-in-plain-card",
    // DataGrid must be full-bleed inside DataGridCard; raw Card adds section chrome/padding semantics.
    pattern: /<Card\b[^>]*>(?:(?!<\/Card>).)*<DataGrid\b/gs,
    message:
      "Do not render DataGrid inside a raw Card. Use DataGridCard and render DataGrid as a direct child.",
  },
  {
    id: "no-tailwind-v3-gradient",
    // Match: bg-gradient-to-{direction} which is Tailwind v3 syntax
    pattern: /bg-gradient-to-[a-z]+/g,
    message: "Use bg-linear-to-* instead of bg-gradient-to-* (Tailwind v4 syntax).",
  },
]

const STRUCTURAL_RULES = [
  {
    id: "no-cardtitle-custom-children",
    message:
      "CardTitle is heading text only. Move supporting text to CardDescription and controls to CardAction.",
    check(content) {
      const violations = []
      const pattern = /<CardTitle\b[^>]*>(?:(?!<\/CardTitle>).)*<(span|p|button|div)\b/gs
      for (const match of content.matchAll(pattern)) {
        violations.push(match.index ?? 0)
      }
      return violations
    },
  },
  {
    id: "no-carddescription-in-cardaction",
    message:
      "Do not put CardDescription inside CardAction. CardAction is for badges, buttons, menus, and compact controls.",
    check(content) {
      const violations = []
      const pattern = /<CardAction\b[^>]*>(?:(?!<\/CardAction>).)*<CardDescription\b/gs
      for (const match of content.matchAll(pattern)) {
        violations.push(match.index ?? 0)
      }
      return violations
    },
  },
  {
    id: "no-cardheader-custom-child",
    message:
      "Do not put custom direct children in CardHeader. Use CardTitle, CardDescription, and CardAction.",
    check(content) {
      const violations = []
      const headerPattern = /<CardHeader\b[^>]*>(?<body>[\s\S]*?)<\/CardHeader>/g
      const primitiveBlockPattern =
        /<Card(?:Title|Description|Action)\b[^>]*>[\s\S]*?<\/Card(?:Title|Description|Action)>/g

      for (const match of content.matchAll(headerPattern)) {
        const body = match.groups?.body ?? ""
        const stripped = body.replace(primitiveBlockPattern, "")
        const customChild = /<([A-Za-z][\w.:-]*)\b/.exec(stripped)
        if (customChild) {
          violations.push((match.index ?? 0) + match[0].indexOf(customChild[0]))
        }
      }
      return violations
    },
  },
]

let errorCount = 0

function lineForIndex(text, index) {
  return text.slice(0, index).split("\n").length
}

for (const filePath of filesToCheck) {
  const absPath = resolve(filePath)
  let content
  try {
    content = readFileSync(absPath, "utf8")
  } catch {
    // File may have been deleted or moved; skip
    continue
  }

  for (const rule of RULES) {
    const matches = [...content.matchAll(rule.pattern)]
    for (const match of matches) {
      const lineNum = lineForIndex(content, match.index ?? 0)
      const line = content.split("\n")[lineNum - 1].trim()
      console.error(`\n${rule.id}`)
      console.error(`  ${filePath}:${lineNum}`)
      console.error(`  ${line.trim()}`)
      console.error(`  → ${rule.message}`)
      errorCount++
    }
  }

  for (const rule of STRUCTURAL_RULES) {
    const matches = rule.check(content)
    for (const index of matches) {
      const lineNum = lineForIndex(content, index)
      const line = content.split("\n")[lineNum - 1].trim()
      console.error(`\n${rule.id}`)
      console.error(`  ${filePath}:${lineNum}`)
      console.error(`  ${line}`)
      console.error(`  → ${rule.message}`)
      errorCount++
    }
  }
}

if (errorCount > 0) {
  console.error(
    `\nFound ${errorCount} canonical-chrome violation(s). Fix before committing.\n`
  )
  process.exit(1)
}
