import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, copyFileSync } from "node:fs"
import { basename, dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { generateEffect, generateLua, generateTypes } from "./generate.js"
import { parseSpec, SpecError } from "./spec.js"

const USAGE = `rivo-fx gen <schemas.json> [options]
rivo-fx create <dir> [--template lua|lua-nui] [--name <resource>]

create: a new resource from a template (lua: server + client; lua-nui: plus a page).

gen: validators and types from one schema file.

  --lua <file>        Lua for shared_script: Fx.S schemas + LuaLS classes
  --namespace <Name>  global table for the Lua file (default: from the file name)
  --ts <file>         TypeScript Effect schemas, for JS/TS resources (@rivolabs/fx)
  --types <file>      plain TypeScript types, for NUI pages
  --check             write nothing; exit 1 if any output is missing or out of date (CI)
`

interface Io {
  out: (s: string) => void
  err: (s: string) => void
}

const pascal = (file: string): string => {
  const base = basename(file).replace(/\.(schema\.)?json$/i, "")
  const name = base
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
    .map((w) => w[0]!.toUpperCase() + w.slice(1))
    .join("")
  return /^[A-Za-z_]/.test(name) ? name : `Schemas${name}`
}

/** Run the CLI with argv (without node and the script). Returns the exit code. */
export const run = (argv: string[], io: Io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }): number => {
  const [command, ...rest] = argv
  if (!command || command === "-h" || command === "--help") {
    io.out(USAGE)
    return command ? 0 : 1
  }
  if (command === "create") return create(rest, io)
  if (command !== "gen") {
    io.err(`unknown command "${command}"\n\n${USAGE}`)
    return 1
  }
  let input: string | undefined
  const opts: Record<string, string | true> = {}
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]!
    if (a === "--check") opts["check"] = true
    else if (a === "--lua" || a === "--ts" || a === "--types" || a === "--namespace") {
      const v = rest[++i]
      if (!v) {
        io.err(`${a} needs a value\n`)
        return 1
      }
      opts[a.slice(2)] = v
    } else if (a.startsWith("-")) {
      io.err(`unknown option ${a}\n\n${USAGE}`)
      return 1
    } else if (input === undefined) input = a
    else {
      io.err(`unexpected argument ${a}\n`)
      return 1
    }
  }
  if (!input) {
    io.err(USAGE)
    return 1
  }
  if (!opts["lua"] && !opts["ts"] && !opts["types"]) {
    io.err("nothing to generate: pass --lua, --ts and/or --types\n")
    return 1
  }

  let spec
  try {
    spec = parseSpec(JSON.parse(readFileSync(input, "utf8")))
  } catch (e) {
    if (e instanceof SpecError || e instanceof SyntaxError) io.err(`${input}: ${e.message}\n`)
    else io.err(`${input}: ${(e as Error).message}\n`)
    return 1
  }

  const namespace = typeof opts["namespace"] === "string" ? opts["namespace"] : pascal(input)
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(namespace)) {
    io.err(`--namespace must be an identifier, got "${namespace}"\n`)
    return 1
  }
  const outputs: Array<[string, (source: string) => string]> = []
  if (typeof opts["lua"] === "string") outputs.push([opts["lua"], (source) => generateLua(spec, { namespace, source })])
  if (typeof opts["ts"] === "string") outputs.push([opts["ts"], (source) => generateEffect(spec, { source })])
  if (typeof opts["types"] === "string") outputs.push([opts["types"], (source) => generateTypes(spec, { source })])

  let stale = 0
  for (const [file, gen] of outputs) {
    const source = relative(dirname(resolve(file)), resolve(input)).replace(/\\/g, "/")
    const text = gen(source)
    if (opts["check"]) {
      const current = existsSync(file) ? readFileSync(file, "utf8") : undefined
      if (current !== text) {
        io.err(`${file} is ${current === undefined ? "missing" : "out of date"}\n`)
        stale++
      }
    } else {
      mkdirSync(dirname(resolve(file)), { recursive: true })
      writeFileSync(file, text)
      io.out(`wrote ${file}\n`)
    }
  }
  if (stale) {
    io.err(`run: rivo-fx gen ${argv.slice(1).filter((a) => a !== "--check").join(" ")}\n`)
    return 1
  }
  return 0
}

// create -----------------------------------------------------------------------

const packageRoot = (): string => resolve(dirname(fileURLToPath(import.meta.url)), "..")

/** The built @rivolabs/fx-nui to copy into new pages: bundled with the CLI, or from the repo. */
const fxNuiBuild = (): string | undefined =>
  [join(packageRoot(), "vendor", "fx-nui.js"), join(packageRoot(), "..", "fx-nui", "dist", "index.js")].find((p) => existsSync(p))

const TEMPLATES: Record<string, string[]> = { lua: ["lua"], "lua-nui": ["lua", "lua-nui"] }
const TEXT = /\.(lua|json|md|html|js|css|txt)$/

const copyTemplate = (from: string, to: string, vars: Record<string, string>): void => {
  for (const entry of readdirSync(from)) {
    const src = join(from, entry)
    const dst = join(to, entry)
    if (statSync(src).isDirectory()) {
      mkdirSync(dst, { recursive: true })
      copyTemplate(src, dst, vars)
    } else if (TEXT.test(entry)) {
      let text = readFileSync(src, "utf8")
      for (const [k, v] of Object.entries(vars)) text = text.split(k).join(v)
      writeFileSync(dst, text)
    } else {
      copyFileSync(src, dst)
    }
  }
}

const create = (args: string[], io: Io): number => {
  let dir: string | undefined
  let template = "lua"
  let name: string | undefined
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!
    if (a === "--template" || a === "--name") {
      const v = args[++i]
      if (!v) {
        io.err(`${a} needs a value\n`)
        return 1
      }
      if (a === "--template") template = v
      else name = v
    } else if (a.startsWith("-")) {
      io.err(`unknown option ${a}\n\n${USAGE}`)
      return 1
    } else if (dir === undefined) dir = a
    else {
      io.err(`unexpected argument ${a}\n`)
      return 1
    }
  }
  if (!dir) {
    io.err(USAGE)
    return 1
  }
  const layers = TEMPLATES[template]
  if (!layers) {
    io.err(`unknown template "${template}" (choose: ${Object.keys(TEMPLATES).join(", ")})\n`)
    return 1
  }
  const resource = name ?? basename(resolve(dir))
  if (!/^[A-Za-z0-9_-]+$/.test(resource)) {
    io.err(`"${resource}" is not a usable resource name (letters, digits, _ and -)\n`)
    return 1
  }
  if (existsSync(dir) && readdirSync(dir).length > 0) {
    io.err(`${dir} already exists and is not empty\n`)
    return 1
  }
  const namespace = pascal(resource)
  const vars = { __NAME__: resource, __NAMESPACE__: namespace }
  mkdirSync(dir, { recursive: true })
  for (const layer of layers) copyTemplate(join(packageRoot(), "templates", layer), dir, vars)

  if (template === "lua-nui") {
    const build = fxNuiBuild()
    if (!build) {
      io.err("could not find the @rivolabs/fx-nui build to copy into web/fx-nui.js\n")
      return 1
    }
    copyFileSync(build, join(dir, "web", "fx-nui.js"))
  }

  const code = run(["gen", join(dir, "shared", "schemas.json"), "--lua", join(dir, "shared", "schemas.lua"), "--namespace", namespace],
    { out: () => {}, err: io.err })
  if (code !== 0) return code

  io.out(`created ${resource} in ${dir} (template: ${template})\n\n`)
  io.out(`  1. put it in your resources folder\n  2. add to server.cfg, after rivo_fx:  ensure ${resource}\n  3. in game: /${resource}${template === "lua" ? " water 2" : ""}\n`)
  return 0
}
