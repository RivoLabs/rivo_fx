import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import type { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { generateEffect, generateLua, generateTypes, parseSpec, run } from "../src/index.js"

const here = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(here, "../../..")
const SPEC_FILE = join(here, "fixtures", "shop.schema.json")
const GEN = join(here, ".gen")
const spec = parseSpec(JSON.parse(readFileSync(SPEC_FILE, "utf8")))

const lua = (() => {
  try {
    execFileSync("lua5.4", ["-v"])
    return true
  } catch {
    return false
  }
})()

describe("parseSpec", () => {
  const bad = (json: unknown) => {
    try {
      parseSpec(json)
    } catch (e) {
      return (e as Error).message
    }
    return "accepted"
  }

  it("orders schemas so references come first", () => {
    expect(spec.schemas.map((s) => s.name)).toEqual(["Rarity", "Item", "Cart", "Paid"])
  })

  it("rejects mistakes with the path of the problem", () => {
    expect(bad({ A: { type: "struct", fields: { x: "nope" } } })).toBe('A.fields.x: unknown type or schema "nope"')
    expect(bad({ A: { type: "string", pattern: "^a" } })).toContain("patterns are not supported")
    expect(bad({ A: { type: "int", min: 5, max: 1 } })).toBe("A: min is greater than max")
    expect(bad({ A: { type: "literal", values: [] } })).toContain("non-empty")
    expect(bad({ A: "B", B: { type: "array", items: "A" } })).toContain("recursive schemas are not supported")
    expect(bad({ "bad-name": "string" })).toContain("identifiers")
    expect(bad({ A: { type: "B" }, B: "string" })).toContain('write the name as a string ("B")')
    expect(bad({ string: "int" })).toContain("built-in")
  })
})

describe("generated code", () => {
  it("emits Lua with LuaLS classes", () => {
    const out = generateLua(spec, { namespace: "Shop", source: "shop.schema.json" })
    expect(out).toContain("---@class Shop.Item")
    expect(out).toContain('---@field rarity Shop.Rarity')
    expect(out).toContain('---@field ["stock-level"]? integer')
    expect(out).toContain("  ['stock-level'] = S.int:optional(),")
    expect(out).toContain("  name = S.string:minChars(1):maxChars(12),")
    expect(out).toContain('---@alias Shop.Rarity "common"|"rare"|"legendary"')
  })

  it("emits TypeScript that typechecks", () => {
    mkdirSync(GEN, { recursive: true })
    writeFileSync(join(GEN, "shop.effect.ts"), generateEffect(spec, { source: "shop.schema.json" }))
    writeFileSync(join(GEN, "shop.types.ts"), generateTypes(spec, { source: "shop.schema.json" }))
    writeFileSync(
      join(GEN, "use.ts"),
      [
        'import type { Cart as PlainCart } from "./shop.types.js"',
        'import { Cart } from "./shop.effect.js"',
        "export const same = (c: Cart): PlainCart => c",
        "export const back = (c: PlainCart): Cart => c",
        ""
      ].join("\n")
    )
    execFileSync("npx", ["tsc", "--ignoreConfig", "--noEmit", "--strict", "--exactOptionalPropertyTypes", "--skipLibCheck", "--module", "NodeNext",
      "--moduleResolution", "NodeNext", "--target", "ES2022", join(GEN, "use.ts")], { cwd: resolve(here, ".."), stdio: "pipe" })
  })
})

// The same inputs through the generated Lua and the generated Effect schemas
// must be accepted or rejected alike.
const corpus: Array<[string, unknown]> = [
  ["Rarity", "rare"],
  ["Rarity", "epic"],
  ["Rarity", 1],
  ["Paid", true],
  ["Paid", "yes"],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Äpfelchen", price: 5, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Äpfelchen-xxx", price: 5, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Äpfelchenäää", price: 5, weight: 0.5, rarity: "common" }], // 12 characters, 15 bytes
  ["Item", { name: "", price: 5, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Apple", price: 5.5, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Apple", price: -1, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Apple", price: 100001, weight: 0.5, rarity: "common" }],
  ["Item", { name: "Apple", price: 5, weight: 0.05, rarity: "common" }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", tags: ["a", "b", "c"] }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", tags: ["a", "b", "c", "d"] }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", tags: ["a", 1] }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", "stock-level": 3 }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", "stock-level": "3" }],
  ["Item", { name: "Apple", price: 5, weight: 0.5 }],
  ["Item", { name: "Apple", price: 5, weight: 0.5, rarity: "common", extra: "stripped" }],
  ["Item", "Apple"],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1.5 }, spot: [1, 2, 3] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3], coupon: "SAVE10" }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3], coupon: false }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3], coupon: true }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3], coupon: "ABC" }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: "x" }, spot: [1, 2, 3] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3, 4] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }, { name: "B", price: 1, weight: 1, rarity: "rare" },
    { name: "C", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "bad" }], totals: { a: 1 }, spot: [1, 2, 3] }],
  ["Cart", { items: [{ name: "A", price: 1, weight: 1, rarity: "rare" }], totals: { a: 1 }, spot: [1, 2, 3], meta: { any: ["thing"] } }]
]

const toLua = (v: unknown): string => {
  if (typeof v === "string") return JSON.stringify(v).replace(/\\u([0-9a-f]{4})/gi, (_, h) => `\\u{${h}}`)
  if (typeof v === "number" || typeof v === "boolean") return String(v)
  if (Array.isArray(v)) return `{ ${v.map(toLua).join(", ")} }`
  if (v && typeof v === "object") return `{ ${Object.entries(v).map(([k, x]) => `[${JSON.stringify(k)}] = ${toLua(x)}`).join(", ")} }`
  throw new Error(`no Lua literal for ${String(v)}`)
}

describe.skipIf(!lua)("Lua and Effect agree", () => {
  it("accepts and rejects the same inputs", async () => {
    mkdirSync(GEN, { recursive: true })
    const luaFile = join(GEN, "shop.lua")
    writeFileSync(luaFile, generateLua(spec, { namespace: "Shop", source: "shop.schema.json" }))
    writeFileSync(join(GEN, "shop.effect.ts"), generateEffect(spec, { source: "shop.schema.json" }))

    const script = [
      `package.path = ${JSON.stringify(ROOT + "/")} .. '?.lua;' .. package.path`,
      `_G.RIVO_FX_ROOT = ${JSON.stringify(ROOT + "/")}`,
      `local Fx = dofile(${JSON.stringify(ROOT + "/init.lua")})`,
      `dofile(${JSON.stringify(luaFile)})`,
      "local cases = {",
      ...corpus.map(([name, value]) => `  { ${JSON.stringify(name)}, ${toLua(value)} },`),
      "}",
      "for i, c in ipairs(cases) do",
      "  local ok = Shop[c[1]]:validate(c[2])",
      "  print(i .. ' ' .. tostring(ok))",
      "end"
    ].join("\n")
    const runner = join(GEN, "run.lua")
    writeFileSync(runner, script)
    const luaResults = execFileSync("lua5.4", [runner], { encoding: "utf8" }).trim().split("\n").map((l) => l.split(" ")[1] === "true")

    const { Schema: S } = await import("effect")
    const effect = (await import(join(GEN, "shop.effect.ts"))) as Record<string, Schema.Top>
    const tsResults = corpus.map(([name, value]) => S.is(effect[name] as never)(value))

    const table = corpus.map(([name, value], i) => ({ name, value: JSON.stringify(value), lua: luaResults[i], ts: tsResults[i] }))
    const disagreements = table.filter((r) => r.lua !== r.ts)
    expect(disagreements).toEqual([])
    // and the corpus really exercises both outcomes
    expect(table.filter((r) => r.lua).length).toBeGreaterThan(8)
    expect(table.filter((r) => !r.lua).length).toBeGreaterThan(8)
  })

  it("generated Lua passes LuaLS", () => {
    const luals = "/tmp/luals/bin/lua-language-server"
    if (!existsSync(luals)) return
    const dir = join(GEN, "luals")
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "shop.lua"), generateLua(spec, { namespace: "Shop", source: "shop.schema.json" }))
    writeFileSync(join(dir, ".luarc.json"), JSON.stringify({ "workspace.library": [join(ROOT, "types")], "diagnostics.globals": ["Shop"] }))
    const out = execFileSync(luals, ["--check", dir, "--checklevel=Information"], { encoding: "utf8" })
    expect(out).toContain("no problems found")
  })
})

describe("cli", () => {
  it("writes outputs, and --check catches stale ones", () => {
    const dir = join(GEN, "cli")
    rmSync(dir, { recursive: true, force: true })
    mkdirSync(dir, { recursive: true })
    const io = { out: () => {}, err: (s: string) => errs.push(s) }
    const errs: string[] = []
    const args = ["gen", SPEC_FILE, "--lua", join(dir, "s.lua"), "--types", join(dir, "s.ts"), "--namespace", "Shop"]
    expect(run([...args, "--check"], io)).toBe(1)
    expect(errs.join("")).toContain("missing")
    expect(run(args, io)).toBe(0)
    expect(run([...args, "--check"], io)).toBe(0)
    writeFileSync(join(dir, "s.lua"), "-- edited\n")
    expect(run([...args, "--check"], io)).toBe(1)
    expect(readFileSync(join(dir, "s.ts"), "utf8")).toContain("export interface Item")
  })

  it("reports spec errors with the file name", () => {
    const errs: string[] = []
    const bad = join(GEN, "bad.json")
    mkdirSync(GEN, { recursive: true })
    writeFileSync(bad, JSON.stringify({ A: { type: "string", pattern: "x" } }))
    expect(run(["gen", bad, "--lua", join(GEN, "x.lua")], { out: () => {}, err: (s) => errs.push(s) })).toBe(1)
    expect(errs.join("")).toContain(`${bad}: A: "pattern" is not valid on string`)
  })
})
