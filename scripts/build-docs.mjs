#!/usr/bin/env node
// Builds the docs outputs from docs/reference/*.md (and docs/MIGRATING.md):
//
//   node scripts/build-docs.mjs                 writes llms.txt and llms-full.md
//   node scripts/build-docs.mjs --check         fails when they are out of date (CI)
//   node scripts/build-docs.mjs --site <dir>    also writes one file per page for
//                                               rivo.software, links rewritten
//
// The page list below is the order of the docs everywhere.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, normalize, relative } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const REPO = "https://github.com/RivoLabs/rivo_fx/blob/main"
const RAW = "https://raw.githubusercontent.com/RivoLabs/rivo_fx/main"
const SITE = "https://rivo.software/docs/products/rivo-fx"

export const PAGES = [
  { file: "docs/reference/introduction.md", slug: "introduction", title: "Introduction" },
  { file: "docs/reference/getting-started.md", slug: "getting-started", title: "Getting started" },
  { file: "docs/reference/core-effects.md", slug: "effects", title: "Effects" },
  { file: "docs/reference/core-errors.md", slug: "errors-and-causes", title: "Errors and causes" },
  { file: "docs/reference/core-concurrency.md", slug: "concurrency", title: "Concurrency" },
  { file: "docs/reference/core-resources.md", slug: "scopes-services-layers", title: "Scopes, services and Layers" },
  { file: "docs/reference/core-schedule.md", slug: "schedule", title: "Schedule" },
  { file: "docs/reference/core-schema.md", slug: "schema", title: "Schema" },
  { file: "docs/reference/streams.md", slug: "streams", title: "Streams" },
  { file: "docs/reference/observability.md", slug: "metrics-tracing-logs", title: "Metrics, tracing and logs" },
  { file: "docs/reference/devtools.md", slug: "devtools", title: "Devtools (/fxdev)" },
  { file: "docs/reference/net-rpc.md", slug: "net-events-and-rpc", title: "Net events and RPC" },
  { file: "docs/reference/fivem-modules.md", slug: "players-config-assets-entities", title: "Players, config, assets, entities, ticks" },
  { file: "docs/reference/data.md", slug: "kvp-state-database-frameworks", title: "KVP, state bags, database, frameworks" },
  { file: "docs/reference/nui.md", slug: "nui", title: "NUI" },
  { file: "docs/reference/js.md", slug: "javascript-typescript", title: "JavaScript and TypeScript (@rivolabs/fx)" },
  { file: "docs/reference/cli.md", slug: "cli", title: "CLI (rivo-fx)" },
  { file: "docs/reference/recipes.md", slug: "recipes", title: "Recipes" },
  { file: "docs/reference/errors.md", slug: "errors-and-gotchas", title: "Errors and gotchas" },
  { file: "docs/MIGRATING.md", slug: "migrating", title: "Moving a resource to Rivo FX" },
]

const read = (f) => readFileSync(join(root, f), "utf8")
const byFile = new Map(PAGES.map((p) => [normalize(p.file), p]))

// The first paragraph after the title, as one line.
function summary(text) {
  const body = text.replace(/^# .*\n+/, "")
  const para = body.split(/\n\s*\n/).find((b) => b.trim() && !b.startsWith("#") && !b.startsWith("```"))
  const line = (para ?? "").replace(/\s+/g, " ").trim()
  const first = line.match(/^(.+?\.)(\s|$)/)
  return first ? first[1] : line
}

// Rewrites relative links in a page. to(page, anchor) gives the target for a
// docs page; anything else in the repo goes to GitHub.
function rewrite(text, from, to) {
  return text.replace(/\]\((?!https?:|#|mailto:)([^)\s]+?)(#[^)\s]*)?\)/g, (m, target, anchor = "") => {
    const resolved = normalize(join(dirname(from), target))
    const page = byFile.get(resolved)
    if (page) return `](${to(page, anchor)})`
    const rel = relative(root, join(root, resolved)).replaceAll("\\", "/")
    return `](${REPO}/${rel}${anchor})`
  })
}

function llmsTxt() {
  const lines = [
    "# Rivo FX",
    "",
    "> Rivo FX is a free, MIT-licensed FiveM library for Lua 5.4 and JavaScript/TypeScript with typed errors, fibers, scopes, Layers and Schema (the Effect model), plus validated net events, typed RPC, asset loading, entities, state bags, KVP, oxmysql, frameworks (ESX, QBCore, Qbox), NUI, streams, metrics, tracing and in-game devtools.",
    "",
    "Resources load it with `shared_script '@rivo_fx/init.lua'` and use the global `Fx`. JS/TS resources use the npm package `@rivolabs/fx` on top of `effect`. Every reference page has one heading per function with its signature, parameters, return value, errors and an example.",
    "",
    "## Docs",
    "",
  ]
  for (const p of PAGES) lines.push(`- [${p.title}](${RAW}/${p.file}): ${summary(read(p.file))}`)
  lines.push(
    "",
    "## Optional",
    "",
    `- [Full reference in one file](${RAW}/llms-full.md): every page above, in order`,
    `- [Wire protocol](${RAW}/docs/PROTOCOL.md): the RPC and net event format shared by Lua and JS`,
    `- [Type definitions](${RAW}/types/rivo_fx.lua): LuaLS annotations for the whole Lua API`,
    `- [Website docs](${SITE}/introduction)`,
    "",
  )
  return lines.join("\n")
}

function llmsFull() {
  const parts = [
    "# Rivo FX reference",
    "",
    "All Rivo FX documentation in one file, for reading start to finish or loading into an AI assistant. Generated from docs/reference by scripts/build-docs.mjs; edit those files, not this one.",
    "",
    "Contents:",
    "",
    ...PAGES.map((p) => `- [${p.title}](#${p.slug})`),
    "",
  ]
  for (const p of PAGES) {
    const body = rewrite(read(p.file), p.file, (page, anchor) => (anchor ? anchor : `#${page.slug}`))
      .replace(/^# .*\n/, "")
      .replace(/^(#{1,5}) /gm, "#$1 ") // every heading one level down, under the page heading
    parts.push(`<a id="${p.slug}"></a>`, "", `## ${p.title}`, body.trim(), "")
  }
  return parts.join("\n")
}

function sitePage(p) {
  return rewrite(read(p.file), p.file, (page, anchor) => `/docs/products/rivo-fx/${page.slug}${anchor}`)
    .replace(/^# .*\n+/, "") // the site shows the title itself
    .trim() + "\n"
}

const args = process.argv.slice(2)
const outputs = { "llms.txt": llmsTxt(), "llms-full.md": llmsFull() }

if (args.includes("--check")) {
  const stale = Object.entries(outputs).filter(([f, text]) => {
    try { return read(f) !== text } catch { return true }
  })
  if (stale.length) {
    console.error(`out of date: ${stale.map(([f]) => f).join(", ")}; run node scripts/build-docs.mjs`)
    process.exit(1)
  }
  console.log("llms.txt and llms-full.md are up to date")
} else {
  for (const [f, text] of Object.entries(outputs)) writeFileSync(join(root, f), text)
  console.log(`wrote llms.txt and llms-full.md (${PAGES.length} pages)`)
}

const site = args.indexOf("--site")
if (site !== -1) {
  const dir = args[site + 1]
  mkdirSync(dir, { recursive: true })
  for (const p of PAGES) writeFileSync(join(dir, `${p.slug}.md`), sitePage(p))
  writeFileSync(join(dir, "pages.json"), JSON.stringify(PAGES.map((p, i) => ({ ...p, order: i, excerpt: summary(read(p.file)) })), null, 2))
  console.log(`wrote ${PAGES.length} site pages to ${dir}`)
}
