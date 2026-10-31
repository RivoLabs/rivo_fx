/**
 * The schema file: named schemas in a language-neutral JSON format.
 *
 *   {
 *     "Item":   { "type": "struct", "fields": {
 *                 "name": { "type": "string", "minLength": 1, "maxLength": 32 },
 *                 "qty":  { "type": "int", "min": 1, "max": 10 },
 *                 "note": { "type": "string", "optional": true } } },
 *     "Rarity": { "type": "literal", "values": ["common", "rare"] },
 *     "Cart":   { "type": "array", "items": "Item", "maxItems": 20 }
 *   }
 *
 * A string is shorthand for a primitive ("string", "number", "int", "boolean",
 * "unknown") or a reference to another named schema. Lengths count characters
 * (code points) on both sides. Patterns are left out on purpose: Lua patterns
 * and JS regexes do not mean the same thing.
 */

export type Literal = string | number | boolean

export type Node = (
  | { kind: "string"; minLength?: number; maxLength?: number }
  | { kind: "number" | "int"; min?: number; max?: number }
  | { kind: "boolean" | "unknown" }
  | { kind: "literal"; values: Literal[] }
  | { kind: "array"; items: Node; minItems?: number; maxItems?: number }
  | { kind: "record"; values: Node }
  | { kind: "struct"; fields: Field[] }
  | { kind: "tuple"; items: Node[] }
  | { kind: "union"; of: Node[] }
  | { kind: "ref"; name: string }
) & { description?: string }

export interface Field {
  name: string
  node: Node
  optional: boolean
}

export interface Spec {
  /** Named schemas, ordered so every reference comes after what it refers to. */
  schemas: Array<{ name: string; node: Node }>
}

export class SpecError extends Error {
  constructor(where: string, message: string) {
    super(`${where}: ${message}`)
    this.name = "SpecError"
  }
}

const PRIMITIVES = new Set(["string", "number", "int", "boolean", "unknown"])
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/

const ALLOWED: Record<string, readonly string[]> = {
  string: ["minLength", "maxLength"],
  number: ["min", "max"],
  int: ["min", "max"],
  boolean: [],
  unknown: [],
  literal: ["values"],
  array: ["items", "minItems", "maxItems"],
  record: ["values"],
  struct: ["fields"],
  tuple: ["items"],
  union: ["of"]
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)

const count = (where: string, v: unknown, key: string): number | undefined => {
  if (v === undefined) return undefined
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
    throw new SpecError(where, `${key} must be a non-negative integer`)
  }
  return v
}

const bound = (where: string, v: unknown, key: string): number | undefined => {
  if (v === undefined) return undefined
  if (typeof v !== "number" || !Number.isFinite(v)) throw new SpecError(where, `${key} must be a finite number`)
  return v
}

const parseNode = (where: string, raw: unknown, names: Set<string>): Node => {
  if (typeof raw === "string") {
    if (PRIMITIVES.has(raw)) return { kind: raw } as Node
    if (names.has(raw)) return { kind: "ref", name: raw }
    throw new SpecError(where, `unknown type or schema "${raw}"`)
  }
  if (!isObject(raw)) throw new SpecError(where, "expected a type name or an object with a \"type\"")
  const type = raw["type"]
  if (typeof type !== "string") throw new SpecError(where, "missing \"type\"")
  if (!(type in ALLOWED)) {
    if (names.has(type)) {
      throw new SpecError(where, `to refer to "${type}" write the name as a string ("${type}"), not as a "type"`)
    }
    throw new SpecError(where, `unknown type "${type}"`)
  }
  for (const key of Object.keys(raw)) {
    if (key === "type" || key === "description" || key === "optional") continue
    if (!ALLOWED[type]!.includes(key)) {
      const hint = key === "pattern" ? " (patterns are not supported: Lua patterns and JS regexes differ)" : ""
      throw new SpecError(where, `"${key}" is not valid on ${type}${hint}`)
    }
  }
  const description = raw["description"]
  if (description !== undefined && typeof description !== "string") throw new SpecError(where, "description must be a string")
  const withDescription = <N extends Node>(n: N): N => (description === undefined ? n : { ...n, description })

  const range = <T extends { min?: number; max?: number } | { minLength?: number; maxLength?: number } | { minItems?: number; maxItems?: number }>(
    lo: number | undefined,
    hi: number | undefined,
    loKey: string,
    hiKey: string,
    build: () => T
  ): T => {
    if (lo !== undefined && hi !== undefined && lo > hi) throw new SpecError(where, `${loKey} is greater than ${hiKey}`)
    return build()
  }

  switch (type) {
    case "string": {
      const minLength = count(where, raw["minLength"], "minLength")
      const maxLength = count(where, raw["maxLength"], "maxLength")
      return withDescription(range(minLength, maxLength, "minLength", "maxLength", () => ({
        kind: "string" as const,
        ...(minLength === undefined ? {} : { minLength }),
        ...(maxLength === undefined ? {} : { maxLength })
      })))
    }
    case "number":
    case "int": {
      const min = bound(where, raw["min"], "min")
      const max = bound(where, raw["max"], "max")
      return withDescription(range(min, max, "min", "max", () => ({
        kind: type,
        ...(min === undefined ? {} : { min }),
        ...(max === undefined ? {} : { max })
      })))
    }
    case "boolean":
    case "unknown":
      return withDescription({ kind: type })
    case "literal": {
      const values = raw["values"]
      if (!Array.isArray(values) || values.length === 0) throw new SpecError(where, "literal needs a non-empty \"values\" array")
      for (const v of values) {
        if (!(typeof v === "string" || typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v)))) {
          throw new SpecError(where, "literal values must be strings, finite numbers or booleans")
        }
      }
      return withDescription({ kind: "literal", values: values as Literal[] })
    }
    case "array": {
      if (raw["items"] === undefined) throw new SpecError(where, "array needs \"items\"")
      const minItems = count(where, raw["minItems"], "minItems")
      const maxItems = count(where, raw["maxItems"], "maxItems")
      const items = parseNode(`${where}.items`, raw["items"], names)
      return withDescription(range(minItems, maxItems, "minItems", "maxItems", () => ({
        kind: "array" as const,
        items,
        ...(minItems === undefined ? {} : { minItems }),
        ...(maxItems === undefined ? {} : { maxItems })
      })))
    }
    case "record": {
      if (raw["values"] === undefined) throw new SpecError(where, "record needs \"values\" (keys are strings)")
      return withDescription({ kind: "record", values: parseNode(`${where}.values`, raw["values"], names) })
    }
    case "struct": {
      const fields = raw["fields"]
      if (!isObject(fields)) throw new SpecError(where, "struct needs a \"fields\" object")
      const out: Field[] = []
      for (const name of Object.keys(fields).sort()) {
        const fieldWhere = `${where}.fields.${name}`
        const value = fields[name]
        const optional = isObject(value) && value["optional"] === true
        if (isObject(value) && value["optional"] !== undefined && typeof value["optional"] !== "boolean") {
          throw new SpecError(fieldWhere, "optional must be true or false")
        }
        out.push({ name, node: parseNode(fieldWhere, value, names), optional })
      }
      return withDescription({ kind: "struct", fields: out })
    }
    case "tuple":
    case "union": {
      const key = type === "tuple" ? "items" : "of"
      const list = raw[key]
      if (!Array.isArray(list) || list.length === 0) throw new SpecError(where, `${type} needs a non-empty "${key}" array`)
      const nodes = list.map((n, i) => parseNode(`${where}.${key}[${i}]`, n, names))
      return withDescription(type === "tuple" ? { kind: "tuple", items: nodes } : { kind: "union", of: nodes })
    }
  }
  throw new SpecError(where, `unknown type "${type}"`)
}

const refsOf = (node: Node, out: Set<string>): Set<string> => {
  switch (node.kind) {
    case "ref":
      out.add(node.name)
      break
    case "array":
      refsOf(node.items, out)
      break
    case "record":
      refsOf(node.values, out)
      break
    case "struct":
      for (const f of node.fields) refsOf(f.node, out)
      break
    case "tuple":
      for (const n of node.items) refsOf(n, out)
      break
    case "union":
      for (const n of node.of) refsOf(n, out)
      break
  }
  return out
}

/** Parse and check a schema file's JSON. Throws SpecError with the path of the problem. */
export const parseSpec = (json: unknown): Spec => {
  if (!isObject(json)) throw new SpecError("schema file", "expected an object of named schemas")
  const entries = Object.entries(json).filter(([k]) => k !== "$schema" && k !== "$comment")
  if (entries.length === 0) throw new SpecError("schema file", "no schemas defined")
  const names = new Set<string>()
  for (const [name] of entries) {
    if (!NAME.test(name)) throw new SpecError(name, "schema names must be identifiers (letters, digits, _)")
    if (PRIMITIVES.has(name)) throw new SpecError(name, `"${name}" is a built-in type name`)
    names.add(name)
  }
  const parsed = new Map<string, Node>()
  for (const [name, raw] of entries) parsed.set(name, parseNode(name, raw, names))

  // Order by dependency; recursive schemas are refused (TS needs hand-written types for them).
  const ordered: Array<{ name: string; node: Node }> = []
  const state = new Map<string, "visiting" | "done">()
  const visit = (name: string, chain: string[]) => {
    if (state.get(name) === "done") return
    if (state.get(name) === "visiting") {
      throw new SpecError(name, `recursive schemas are not supported (${[...chain, name].join(" -> ")})`)
    }
    state.set(name, "visiting")
    for (const dep of [...refsOf(parsed.get(name)!, new Set())].sort()) visit(dep, [...chain, name])
    state.set(name, "done")
    ordered.push({ name, node: parsed.get(name)! })
  }
  for (const name of [...names]) visit(name, [])
  return { schemas: ordered }
}
