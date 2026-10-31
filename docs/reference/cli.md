# CLI: rivo-fx

`@rivolabs/fx-cli` installs the `rivo-fx` command. `rivo-fx create` writes a new Lua resource from
a template, and `rivo-fx gen` turns one JSON schema file into matching validators and types for
every side of a resource: Lua (`Fx.S` schemas with LuaLS classes), TypeScript Effect schemas for
[`@rivolabs/fx`](js.md) resources, and plain TypeScript types for NUI pages. This page covers every
command, option, schema type, exit code and error message.

## Install and run

```sh
npx rivo-fx <command> ...                 # no install
pnpm add -D @rivolabs/fx-cli              # or pin it in a project, then: pnpm rivo-fx ...
```

- Needs Node 20 or newer.
- The package also exports `run`, `parseSpec`, `SpecError`, `generateLua`, `generateEffect` and `generateTypes` for use from scripts.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success, `--help`/`-h`, or `gen --check` found every output up to date |
| `1` | any error, `rivo-fx` with no arguments (prints usage), or `gen --check` found a stale or missing output |

Messages go to stderr, except the usage text for `--help`/`-h` and no arguments (stdout) and the
`wrote <file>` / `created ...` lines (stdout).

## Commands

### rivo-fx --help

```sh
rivo-fx --help
rivo-fx -h
rivo-fx
```

- Returns: prints the usage text. Exit code `0` for `--help` and `-h`, `1` with no arguments.
- Notes: an unknown command prints `unknown command "<name>"` followed by the usage, and exits `1`.
- Example:

```sh
$ npx rivo-fx --help
rivo-fx gen <schemas.json> [options]
rivo-fx create <dir> [--template lua|lua-nui] [--name <resource>]
...
```

### rivo-fx create(dir, --template, --name)

```sh
rivo-fx create <dir> [--template lua|lua-nui] [--name <resource>]
```

- Parameters:
  - `<dir>`: where to write the resource. It may not exist yet, or must be empty.
  - `--template <name>`: `lua` (default) or `lua-nui`.
  - `--name <resource>`: the resource name. Defaults to the last part of `<dir>`. Letters, digits, `_` and `-` only.
- Returns: writes the files, runs `gen` on `shared/schemas.json` to produce `shared/schemas.lua`, prints `created <name> in <dir> (template: <template>)` and three next steps, exits `0`.
- Fails with (exit `1`):
  - no `<dir>`: prints the usage;
  - `--template needs a value` / `--name needs a value`;
  - `unknown template "<name>" (choose: lua, lua-nui)`;
  - `"<name>" is not a usable resource name (letters, digits, _ and -)`;
  - `<dir> already exists and is not empty`;
  - `unknown option <flag>` followed by the usage (for example `--check`, which only `gen` takes);
  - `unexpected argument <arg>` for a second positional argument;
  - `could not find the @rivolabs/fx-nui build to copy into web/fx-nui.js` (`lua-nui` only, when the bundled copy is missing).
- Notes:
  - The Lua namespace for the generated schemas is the resource name in PascalCase: `my_shop` gives `MyShop`. A name that starts with a digit gets a `Schemas` prefix.
  - Template files have `__NAME__` replaced by the resource name and `__NAMESPACE__` by the namespace.
  - The resource depends on `rivo_fx` and on the running framework through `Fx.framework.auto` (ESX, QBCore, Qbox, or the in-memory standalone wallet). Start it after `rivo_fx` in `server.cfg`.
- Example:

```sh
$ npx rivo-fx create my_shop
created my_shop in my_shop (template: lua)

  1. put it in your resources folder
  2. add to server.cfg, after rivo_fx:  ensure my_shop
  3. in game: /my_shop water 2
```

#### Template lua

| File | What it does |
|---|---|
| `fxmanifest.lua` | `lua54 'yes'`, `dependency 'rivo_fx'`, shared scripts `@rivo_fx/init.lua` and `shared/schemas.lua` |
| `shared/schemas.json` | `Item` (literal `water`, `bread`, `phone`), `BuyInput { item, qty 1..10 }`, `Receipt { item, qty, paid, cash }` |
| `shared/schemas.lua` | generated from `schemas.json`: the global table `<Namespace>` with `Item`, `BuyInput`, `Receipt` |
| `server.lua` | `Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))` and `Fx.rpc.register('<name>:buy', { input, output, rateLimit = '5/s' }, ...)`, which charges cash with `removeMoney` (fails `InsufficientFunds`) |
| `client.lua` | command `/<name> <item> [qty]`: calls the RPC with a 5 s timeout and handles `InsufficientFunds` and `RpcInvalidInput` with `catchTag` |
| `.luarc.json` | LuaLS: Lua 5.4, `workspace.library` set to `../rivo_fx/types` |
| `README.md` | how to regenerate the schemas and start the resource |

#### Template lua-nui

Everything in `lua`, with these files replaced or added:

| File | What it does |
|---|---|
| `fxmanifest.lua` | adds `ui_page 'web/index.html'` and `files { 'web/index.html', 'web/app.js', 'web/fx-nui.js' }` |
| `client.lua` | command `/<name>` opens the page. `Fx.nui.handle('buy', ...)` forwards to the server RPC, so its tagged errors reach the page. `Fx.nui.handle('close', ...)` interrupts the fiber that holds `Fx.nui.useFocus()` |
| `web/index.html`, `web/app.js` | the page: `fetchNui('buy', ...)`, `isNuiError(e, 'InsufficientFunds')`, `onMessage('open', ...)`, and `mockNui` so it runs in a normal browser |
| `web/fx-nui.js` | a copy of the built `@rivolabs/fx-nui` |

The `README.md` from the `lua` template is kept, so it still describes the `/<name> <item> [qty]`
command of the plain template.

### rivo-fx gen(schemas.json, --lua, --ts, --types, --namespace, --check)

```sh
rivo-fx gen <schemas.json> [--lua <file>] [--ts <file>] [--types <file>] [--namespace <Name>] [--check]
```

- Parameters:
  - `<schemas.json>`: the schema file (format below). Exactly one.
  - `--lua <file>`: write a Lua file for `shared_script`: `Fx.S` schemas plus LuaLS classes.
  - `--ts <file>`: write TypeScript Effect schemas (`import { Schema } from "effect"`) and their types, for JS/TS resources.
  - `--types <file>`: write plain TypeScript types (no imports), for NUI pages.
  - `--namespace <Name>`: the global table the Lua file defines. Defaults to the schema file name in PascalCase, without `.schema.json` or `.json`: `shop.schema.json` gives `Shop`, `my-items.json` gives `MyItems`. Only affects `--lua`.
  - `--check`: write nothing. Compare each output with what would be generated.
- Returns: writes each requested file (creating directories) and prints `wrote <file>` per file. Exit `0`.
- Fails with (exit `1`):
  - no schema file: prints the usage;
  - `nothing to generate: pass --lua, --ts and/or --types`;
  - `--lua needs a value` (same for `--ts`, `--types`, `--namespace`);
  - `--namespace must be an identifier, got "<value>"`;
  - `unknown option <flag>` followed by the usage;
  - `unexpected argument <arg>`;
  - `<file>: <message>` when the file cannot be read, is not valid JSON, or fails the schema rules (messages below);
  - with `--check`: `<file> is missing` or `<file> is out of date` per stale output, then `run: rivo-fx gen <same arguments without --check>`.
- Notes:
  - Each output starts with `Generated by rivo-fx gen from <schema path relative to the output>. Do not edit; ...`. `--check` compares the whole text, header included.
  - Schemas are emitted in dependency order, and struct fields in alphabetical order.
  - Load the Lua file after `@rivo_fx/init.lua`: it uses `Fx.S`.
- Example:

```sh
$ npx rivo-fx gen shared/shop.schema.json --lua shared/schemas.lua --ts src/schemas.ts --types web/src/schemas.ts
wrote shared/schemas.lua
wrote src/schemas.ts
wrote web/src/schemas.ts

$ npx rivo-fx gen shared/shop.schema.json --lua shared/schemas.lua --check   # in CI
shared/schemas.lua is out of date
run: rivo-fx gen shared/shop.schema.json --lua shared/schemas.lua
```

## The schema file

A JSON object of named schemas. Names must be identifiers (`[A-Za-z_][A-Za-z0-9_]*`) and may not
be a built-in type name. The keys `$schema` and `$comment` are ignored.

```json
{
  "Rarity": { "type": "literal", "values": ["common", "rare"] },
  "Item": {
    "type": "struct",
    "description": "Something the shop sells.",
    "fields": {
      "name":   { "type": "string", "minLength": 1, "maxLength": 32 },
      "price":  { "type": "int", "min": 0 },
      "rarity": "Rarity",
      "tags":   { "type": "array", "items": "string", "maxItems": 3, "optional": true }
    }
  },
  "Cart": { "type": "array", "items": "Item", "maxItems": 20 }
}
```

A node is either a string or an object with a `"type"`:

- A string is a primitive (`"string"`, `"number"`, `"int"`, `"boolean"`, `"unknown"`) or the name of another schema in the file.
- Any object node may have `"description"` (a string). It ends up in the generated comments.
- A struct field may have `"optional": true`.

| `type` | Options | Lua (`--lua`) | Effect (`--ts`) | Plain type (`--types`) |
|---|---|---|---|---|
| `string` | `minLength`, `maxLength` (non-negative integers) | `S.string:minChars(n):maxChars(n)` | `Schema.String.check(Schema.isMinCodePoints(n), Schema.isMaxCodePoints(n))` | `string` |
| `number` | `min`, `max` (finite numbers) | `S.number:min(n):max(n)` | `Schema.Finite.check(Schema.isGreaterThanOrEqualTo(n), Schema.isLessThanOrEqualTo(n))` | `number` |
| `int` | `min`, `max` | `S.int:min(n):max(n)` | `Schema.Int.check(...)` | `number` |
| `boolean` | none | `S.boolean` | `Schema.Boolean` | `boolean` |
| `unknown` | none | `S.unknown` | `Schema.Unknown` | `unknown` |
| `literal` | `values`: non-empty array of strings, finite numbers or booleans | `S.literal(a, b)` | `Schema.Literal(a)` or `Schema.Literals([a, b])` | `"a" \| "b"` |
| `array` | `items` (required), `minItems`, `maxItems` | `S.array(x):minItems(n):maxItems(n)` | `Schema.Array(x).check(Schema.isMinLength(n), Schema.isMaxLength(n))` | `ReadonlyArray<x>` |
| `record` | `values` (required); keys are strings | `S.record(S.string, x)` | `Schema.Record(Schema.String, x)` | `{ readonly [key: string]: x }` |
| `struct` | `fields` (required object) | `S.struct { ... }`, optional fields get `:optional()` | `Schema.Struct({ ... })`, optional fields get `Schema.optionalKey(...)` | `interface` with `readonly` fields |
| `tuple` | `items`: non-empty array | `S.tuple(a, b)` | `Schema.Tuple([a, b])` | `readonly [a, b]` |
| `union` | `of`: non-empty array; the first match wins | `S.union(a, b)` | `Schema.Union([a, b])` | `a \| b` |

- String lengths count characters (code points), not bytes, on both sides.
- Not supported, on purpose: string patterns (Lua patterns and JS regexes do not mean the same thing) and recursive schemas.
- In the Lua output, field names that are Lua keywords or not identifiers are quoted (`['end'] = S.boolean`).

### Generated output

For the `Rarity`/`Item`/`Cart` file above saved as `shared/shop.schema.json`,
`rivo-fx gen shared/shop.schema.json --lua shared/shop.lua --ts src/shop.ts --types web/shop.ts`
writes these three files. `shared/shop.lua`:

```lua
-- Generated by rivo-fx gen from shop.schema.json. Do not edit; change the schema file and run it again.
-- Load after @rivo_fx/init.lua. Values decoded by Shop.<Name>:validate(v) match ---@class Shop.<Name>.
local S = Fx.S

Shop = Shop or {}

---@alias Shop.Rarity "common"|"rare"
---@type Fx.Schema<Shop.Rarity>
Shop.Rarity = S.literal('common', 'rare')

---Something the shop sells.
---@class Shop.Item
---@field name string
---@field price integer
---@field rarity Shop.Rarity
---@field tags? string[]
---@type Fx.Schema<Shop.Item>
Shop.Item = S.struct {
  name = S.string:minChars(1):maxChars(32),
  price = S.int:min(0),
  rarity = Shop.Rarity,
  tags = S.array(S.string):maxItems(3):optional(),
}

---@alias Shop.Cart Shop.Item[]
---@type Fx.Schema<Shop.Cart>
Shop.Cart = S.array(Shop.Item):maxItems(20)

return Shop
```

`src/shop.ts`:

```ts
// Generated by rivo-fx gen from ../shared/shop.schema.json. Do not edit; change the schema file and run it again.
import { Schema } from "effect"

export const Rarity = Schema.Literals(["common", "rare"])
export type Rarity = typeof Rarity.Type

// Something the shop sells.
export const Item = Schema.Struct({
  name: Schema.String.check(Schema.isMinCodePoints(1), Schema.isMaxCodePoints(32)),
  price: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  rarity: Rarity,
  tags: Schema.optionalKey(Schema.Array(Schema.String).check(Schema.isMaxLength(3)))
})
export type Item = typeof Item.Type

export const Cart = Schema.Array(Item).check(Schema.isMaxLength(20))
export type Cart = typeof Cart.Type
```

`web/shop.ts`:

```ts
// Generated by rivo-fx gen from ../shared/shop.schema.json. Do not edit; change the schema file and run it again.

export type Rarity = "common" | "rare"

/** Something the shop sells. */
export interface Item {
  readonly name: string
  readonly price: number
  readonly rarity: Rarity
  readonly tags?: ReadonlyArray<string>
}

export type Cart = ReadonlyArray<Item>
```

Use them:

```lua
-- fxmanifest.lua
shared_scripts { '@rivo_fx/init.lua', 'shared/shop.lua' }

-- server.lua
Fx.rpc.register('shop:buy', { input = Shop.Item }, function(src, item) return Fx.succeed(item.name) end)
```

```ts
import { Item } from "./shop.js"
yield* Rpc.register("shop:buy", { input: Item }, (source, item) => Effect.succeed(item.name))
```

### Schema file errors

Each message is printed as `<file>: <where>: <message>`, where `<where>` is the path to the
problem (`Item.fields.tags.items`).

| Message | Cause |
|---|---|
| `schema file: expected an object of named schemas` | the top level is not an object |
| `schema file: no schemas defined` | the object is empty (apart from `$schema`/`$comment`) |
| `schema names must be identifiers (letters, digits, _)` | a top-level name like `1x` |
| `"<name>" is a built-in type name` | a top-level name like `string` |
| `unknown type or schema "<name>"` | a string node that is not a primitive or a schema name |
| `expected a type name or an object with a "type"` | a node that is a number, array or `null` |
| `missing "type"` | an object node without `type` |
| `unknown type "<type>"` | `type` is not one of the eleven types |
| `to refer to "<name>" write the name as a string ("<name>"), not as a "type"` | `{ "type": "Item" }` instead of `"Item"` |
| `"<key>" is not valid on <type>` | an option that type does not take |
| `"pattern" is not valid on string (patterns are not supported: Lua patterns and JS regexes differ)` | a `pattern` option |
| `description must be a string` | |
| `minLength must be a non-negative integer` | also `maxLength`, `minItems`, `maxItems` |
| `min must be a finite number` | also `max` |
| `min is greater than max` | also `minLength`/`maxLength`, `minItems`/`maxItems` |
| `literal needs a non-empty "values" array` | |
| `literal values must be strings, finite numbers or booleans` | for example `null` |
| `array needs "items"` | |
| `record needs "values" (keys are strings)` | |
| `struct needs a "fields" object` | |
| `tuple needs a non-empty "items" array` / `union needs a non-empty "of" array` | |
| `optional must be true or false` | |
| `recursive schemas are not supported (A -> B -> A)` | a schema that refers back to itself |

Invalid JSON prints the parser's message (`<file>: Expected property name or '}' in JSON at
position 1 ...`). A missing file prints the system error (`<file>: ENOENT: no such file or
directory, open '<file>'`).

## Where Lua and JS can still differ

The CLI's test suite runs one corpus of inputs through the generated Lua and the generated Effect
schemas and requires them to agree. Data that has no single meaning in both languages can still
differ:

- `null`: Lua has only `nil`, so an optional field set to `null` is absent in Lua but rejected by Effect.
- `{}` and `[]` are the same empty table in Lua.
- A struct in Lua drops unknown keys by default; Effect's `Schema.Struct` also strips them on decode. Both accept extra keys.

See [Schema](core-schema.md) for `Fx.S` and [JS and TypeScript](js.md) for using the Effect output.
