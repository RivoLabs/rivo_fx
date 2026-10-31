# @rivolabs/fx-cli

```sh
npx rivo-fx create my_shop [--template lua|lua-nui]   # a new resource
npx rivo-fx gen schemas.json --lua ... --ts ... --types ...
```

`create` writes a working resource: a validated, rate-limited RPC that charges
through the running framework, a client command that handles the typed
failures, a schema file with its generated Lua, and a `.luarc.json`. With
`--template lua-nui` it adds a page that calls the same handlers through
`@rivolabs/fx-nui` and keeps NUI focus for exactly as long as it is open.

`rivo-fx gen` turns one schema file into matching validators and types for every
side of a resource: Lua (`Fx.S` schemas with LuaLS classes), TypeScript Effect
schemas for `@rivolabs/fx` resources, and plain TypeScript types for NUI pages.

```sh
npx rivo-fx gen shared/shop.schema.json \
  --lua shared/schemas.lua \
  --ts src/schemas.ts \
  --types web/src/schemas.ts
```

Add `--check` in CI to fail when a generated file is missing or out of date.

## The schema file

```json
{
  "Rarity": { "type": "literal", "values": ["common", "rare"] },
  "Item": {
    "type": "struct",
    "description": "Something the shop sells.",
    "fields": {
      "name":  { "type": "string", "minLength": 1, "maxLength": 32 },
      "price": { "type": "int", "min": 0 },
      "rarity": "Rarity",
      "tags":  { "type": "array", "items": "string", "maxItems": 3, "optional": true }
    }
  },
  "Cart": { "type": "array", "items": "Item", "maxItems": 20 }
}
```

| type | options |
|---|---|
| `string` | `minLength`, `maxLength` (characters, not bytes, on both sides) |
| `number`, `int` | `min`, `max` (`number` is finite) |
| `boolean`, `unknown` | |
| `literal` | `values`: strings, numbers, booleans |
| `array` | `items`, `minItems`, `maxItems` |
| `record` | `values` (keys are strings) |
| `struct` | `fields`; a field may add `"optional": true` |
| `tuple` | `items` |
| `union` | `of` (the first match wins) |

A string stands for a primitive (`"string"`, `"int"`, ...) or another schema by
name. Any node may have a `description`; it ends up in the generated comments.

Not supported, on purpose: string patterns (Lua patterns and JS regexes do not
mean the same thing) and recursive schemas.

## In Lua

```lua
-- fxmanifest.lua
shared_scripts { '@rivo_fx/init.lua', 'shared/schemas.lua' }

-- anywhere
Fx.rpc.register('shop:buy', { input = Shop.Item }, function(src, item) ... end)
```

The Lua file defines a global table named after the schema file (`shop.schema.json`
gives `Shop`; change it with `--namespace`).

## Where Lua and JS can still differ

The test suite runs one corpus of inputs through the generated Lua and the
generated Effect schemas and requires them to agree. What cannot agree is data
that has no single meaning in both languages:

- `null`: Lua has only `nil`, so an optional field set to `null` is absent in
  Lua but rejected by Effect.
- `{}` and `[]` are the same empty table in Lua.
