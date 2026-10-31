# Core schema

This page covers `Fx.S` (also available as `Fx.Schema`), runtime validation for anything that crosses a trust boundary: net event payloads, RPC input and output, NUI messages, convars, config files, KVP and state bags. A schema checks a value and returns a cleaned copy with defaults and transforms applied, or a message that says what is wrong and where. `Fx.net.handle`, `Fx.rpc.register`, `Fx.nui.handle`, `Fx.config`, `Fx.kvp` and `Fx.state` take these schemas directly (see [Net and RPC](net-rpc.md) and [FiveM modules](fivem-modules.md)).

Examples print values with a `--> result` comment showing what they print.

```lua
local S = Fx.S
local Deposit = S.struct {
  amount = S.int:between(1, 1000000),
  account = S.enum { 'cash', 'bank' }:default('bank'),
  note = S.string:maxChars(64):optional(),
}
local ok, value = Deposit:validate({ amount = 500, hacked = true })
print(ok, value.amount, value.account, value.hacked) --> true 500 bank nil
print(Deposit:validate({ amount = 0 })) --> false amount: must be between 1 and 1000000
```

## Rules that apply everywhere

- **Output is a copy.** Containers (`struct`, `array`, `tuple`, `record`, `tagged`) build new tables. The input is never modified.
- **Unknown struct fields are dropped** by default. `S.struct(fields, { extra = 'error' })` rejects them and `{ extra = 'keep' }` passes them through unchecked. See [S.struct](#sstructfields-opts).
- **Missing means `nil`.** A struct field that is absent is checked as `nil`, so it fails unless the field schema is `optional()`, has a `default(...)`, or accepts `nil` (`S.unknown`, `S.any`, `S['nil']`).
- **`nil` is handled before the type check.** For a `nil` input, a `default` is used if there is one, else `optional()` accepts it; refinements do not run. So `S.int:optional():min(1)` and `S.int:min(1):optional()` both accept `nil`.
- **Defaults are not validated.** The default value (or the result of the default function) is returned as is, without type checks, refinements or transforms.
- **Schemas are immutable.** Every modifier returns a new schema; the original is unchanged and can be reused.
- **Refinements are not type guards.** They run after the base check and compare with Lua operators, so put them on the right base type. `S.string:min(1)` or `S.int:minLen(1)` raise a Lua error (`attempt to compare ...`) when validated, instead of returning `false`.
- **Fields are checked in sorted key order**, and the first problem is reported.

## Error messages

A failed check returns one message: `<path>: <problem>`, or just `<problem>` at the top level.

- Paths join struct keys with `.` and array or tuple indexes with `[i]`: `items[2].id: expected integer, got "x"`, `[2]: expected string, got nil` (top-level tuple), `car.plate: expected string, got 1`.
- Values are described as: strings quoted (`"x"`), or `string of length N` when longer than 32 bytes; numbers, booleans and `nil` with `tostring`; any other type by its type name (`table`, `function`).
- `schema:decode` and `schema:parse` wrap the message in a `ParseError { message = message }`.

```lua
local S = Fx.S
local Order = S.struct { items = S.array(S.struct { id = S.int, qty = S.int:between(1, 10) }) }
print(Order:validate({ items = { { id = 1, qty = 2 }, { id = 'x', qty = 1 } } })) --> false items[2].id: expected integer, got "x"
print(S.int:validate(string.rep('9', 40))) --> false expected integer, got string of length 40
```

## Checking values

### schema:validate(input)

```lua
schema:validate(input: any) -> (true, T) | (false, string)
```

- **Returns:** `true` and the decoded value, or `false` and the message.
- **Notes:** never raises for bad input (only for misuse such as a refinement on the wrong base type).

```lua
local S = Fx.S
print(S.int:validate(3.0)) --> true 3
print(S.int:validate('3')) --> false expected integer, got "3"
```

### schema:decode(input)

```lua
schema:decode(input: any) -> Effect<T, ParseError>
```

- **Returns:** an effect that succeeds with the decoded value.
- **Fails with:** `ParseError { message = <message> }`. A Lua error raised during the check is a defect.

```lua
local S = Fx.S
local Amount = S.int:positive()
local exit = Fx.runSyncExit(Amount:decode(-5))
local e = Fx.Cause.failureOption(exit.cause)
print(e._tag, e.message) --> ParseError must be positive
print(Fx.runSync(Amount:decode(250))) --> 250
```

### schema:parse(input)

```lua
schema:parse(input: any) -> T
```

- **Returns:** the decoded value.
- **Fails with:** raises a `ParseError` table (a tagged error) with `error(..., 2)`. Inside effect code, that becomes a `ParseError` failure.

```lua
local S = Fx.S
local ok, err = pcall(function() return S.string:parse(42) end)
print(ok, err._tag, tostring(err)) --> false ParseError ParseError: expected string, got 42
local eff = Fx.gen(function() return S.int:parse('lots') end)
print(Fx.Cause.failureOption(Fx.runSyncExit(eff).cause)._tag) --> ParseError
```

### schema:is(input)

```lua
schema:is(input: any) -> boolean
```

- **Returns:** `true` when the input passes. Only the boolean, no value.

```lua
local S = Fx.S
print(S.netId:is(12), S.netId:is(0)) --> true false
```

## Primitives

### S.string

```lua
S.string: Schema<string>
```

- **Notes:** any Lua string. Use `minChars`/`maxChars` for user-visible length and `minLen`/`maxLen` for byte length.

```lua
print(Fx.S.string:validate(5)) --> false expected string, got 5
```

### S.number

```lua
S.number: Schema<number>
```

- **Notes:** any finite number. NaN, `math.huge` and `-math.huge` are rejected. Strings are not converted.

```lua
local S = Fx.S
print(S.number:is(1.5), S.number:is(0 / 0), S.number:is('1')) --> true false false
```

### S.int and S.integer

```lua
S.int: Schema<integer>
S.integer: Schema<integer>  -- same schema
```

- **Notes:** an integer. A float with no fractional part (`3.0`, as JSON decoding often produces) is accepted and converted to a Lua integer. `2.5` and strings are rejected.

```lua
local S = Fx.S
local _, v = S.int:validate(3.0)
print(math.type(v), S.int:is(2.5)) --> integer false
```

### S.boolean

```lua
S.boolean: Schema<boolean>
```

```lua
print(Fx.S.boolean:validate('true')) --> false expected boolean, got "true"
```

### S.unknown and S.any

```lua
S.unknown: Schema<any>
S.any: Schema<any>  -- same schema
```

- **Notes:** accepts every value, including `nil`. An explicit opt-out of validation for one field.

```lua
local S = Fx.S
local Meta = S.struct { id = S.int, extra = S.unknown }
local ok, v = Meta:validate({ id = 1, extra = { anything = true } })
print(ok, v.extra.anything) --> true true
```

### S['nil']

```lua
S['nil']: Schema<nil>
```

- **Notes:** accepts only `nil` (`nil` is a Lua keyword, hence the brackets).

```lua
print(Fx.S['nil']:validate(1)) --> false expected nil, got 1
```

## Literals

### S.literal(...)

```lua
S.literal(...: any) -> Schema<any>
```

- **Parameters:** the allowed values, compared with `==`.
- **Notes:** the message lists them: `expected "cash" | "bank", got "x"`. The schema has a `values` field with the list.

```lua
local S = Fx.S
local Seat = S.literal(-1, 0, 1, 2)
print(Seat:is(0), Seat:validate(5)) --> true false expected -1 | 0 | 1 | 2, got 5
```

### S.enum(list)

```lua
S.enum(list: any[]) -> Schema<any>
```

- **Parameters:** a list of allowed values. Same as `S.literal(table.unpack(list))`.

```lua
local Account = Fx.S.enum { 'cash', 'bank', 'crypto' }
print(Account:validate('gold')) --> false expected "cash" | "bank" | "crypto", got "gold"
```

## Containers

### S.array(item)

```lua
S.array(item: Schema<T>) -> Schema<T[]>
```

- **Parameters:** `item`, the schema for every element.
- **Notes:** the input must be a table whose keys are exactly the integers `1..#t`. A table with any other key (`x = 3`, or a hole such as `{ [1] = 1, [3] = 3 }`) is rejected with `expected array, got table with key ...`. An empty table is an empty array. Use `maxItems(n)` to cap the length (always cap arrays from clients).

```lua
local S = Fx.S
local Plates = S.array(S.string:maxChars(8)):maxItems(5)
print(Plates:is({ 'ABC123', 'XYZ789' }), Plates:is({ 'ABC', x = 1 })) --> true false
print(Plates:validate({ 'ABC123', 12 })) --> false [2]: expected string, got 12
```

### S.tuple(...)

```lua
S.tuple(...: Schema) -> Schema<any[]>
```

- **Parameters:** one schema per position.
- **Notes:** a missing position is checked as `nil`. Elements beyond the last schema, or non-integer keys, are rejected with `unexpected tuple element <key>`.

```lua
local S = Fx.S
local Coords = S.tuple(S.number, S.number, S.number)
print(Coords:is({ 215.4, -810.1, 30.7 })) --> true
print(Coords:validate({ 1, 2, 3, 4 })) --> false unexpected tuple element 4
```

### S.struct(fields, opts?)

```lua
S.struct(fields: table<string, Schema>, opts?: { extra?: 'strip' | 'error' | 'keep' }) -> Schema<table>
S.object(fields, opts?)  -- same function
```

- **Parameters:** `fields`, a table from key to schema. `opts.extra`, what to do with keys of the input that are not in `fields`:
  - `'strip'` (default): drop them from the output;
  - `'error'`: fail with `<key>: unexpected field`;
  - `'keep'`: copy them to the output unchecked.
- **Returns:** a schema whose output holds the decoded known fields (and, with `'keep'`, the extra ones).
- **Notes:** non-table input fails with `expected object, got ...`. The schema has a `fields` field.

```lua
local S = Fx.S
local Buy = S.struct { item = S.string:maxChars(32), qty = S.int:between(1, 10) }
local _, v = Buy:validate({ item = 'water', qty = 2, price = 0 })
print(v.item, v.qty, v.price) --> water 2 nil
local Strict = S.struct({ item = S.string }, { extra = 'error' })
print(Strict:validate({ item = 'water', price = 0 })) --> false price: unexpected field
```

### S.record(keySchema, valueSchema)

```lua
S.record(keySchema: Schema<K>, valueSchema: Schema<V>) -> Schema<table<K, V>>
```

- **Parameters:** a schema for every key and one for every value.
- **Returns:** a schema whose output uses the decoded keys and values.
- **Notes:** the error path is the key: `bob: expected integer, got "x"`. Cap the size with `maxEntries(n)`.

```lua
local S = Fx.S
local Inventory = S.record(S.string:maxChars(32), S.int:nonNegative()):maxEntries(50)
print(Inventory:is({ water = 3, bread = 1 })) --> true
print(Inventory:validate({ water = -1 })) --> false water: must be >= 0
```

### S.union(...)

```lua
S.union(...: Schema) -> Schema<any>
```

- **Parameters:** the member schemas, tried in order.
- **Returns:** a schema whose output is that of the first member that matches.
- **Notes:** when none match, the message lists every member's message: `no union member matched (<msg1>; <msg2>)`. The schema has a `members` field.

```lua
local S = Fx.S
local Target = S.union(S.int:positive(), S.string)
print(Target:is(5), Target:is('all')) --> true true
print(Target:validate(true)) --> false no union member matched (expected integer, got true; expected string, got true)
```

### S.tagged(field, variants)

```lua
S.tagged(field: string, variants: table<string, Schema>) -> Schema<table>
```

- **Parameters:** `field`, the discriminator key. `variants`, a table from discriminator value to schema (usually a struct).
- **Returns:** a schema that picks the variant by `input[field]`, validates the whole input with it, and copies the discriminator into the output.
- **Notes:** the variant struct does not need to list `field`. An unknown discriminator fails with `<field>: unknown variant <value>`.

```lua
local S = Fx.S
local Payment = S.tagged('type', {
  cash = S.struct { amount = S.int:positive() },
  card = S.struct { amount = S.int:positive(), last4 = S.string:len(4) },
})
local _, v = Payment:validate({ type = 'card', amount = 90, last4 = '4242', cvv = '123' })
print(v.type, v.amount, v.last4, v.cvv) --> card 90 4242 nil
print(Payment:validate({ type = 'crypto', amount = 1 })) --> false type: unknown variant "crypto"
```

### S.lazy(fn)

```lua
S.lazy(fn: fun(): Schema) -> Schema<any>
```

- **Parameters:** `fn`, returns the schema. It is called on first use and cached.
- **Notes:** for recursive schemas.

```lua
local S = Fx.S
local Menu
Menu = S.struct {
  label = S.string,
  children = S.array(S.lazy(function() return Menu end)):optional(),
}
print(Menu:is({ label = 'Garage', children = { { label = 'Store vehicle' } } })) --> true
print(Menu:validate({ label = 'Garage', children = { { label = 5 } } })) --> false children[1].label: expected string, got 5
```

## FiveM types

### S.vector2, S.vector3 and S.vector4

```lua
S.vector2: Schema<vector2>
S.vector3: Schema<vector3>
S.vector4: Schema<vector4>
```

- **Notes:**
  - Accepts a CfxLua vector of the same size, a table `{ x = , y = , z = , w = }`, or a list `{ x, y, z, w }` (named components win over positions).
  - Every component must be a finite number; the error path names it: `z: expected number, got nil`.
  - In FiveM the output is a real `vector2`/`vector3`/`vector4`. Outside FiveM (tests, where the `vector3` global does not exist) it is a plain table `{ x = , y = , z = }`.
  - A vector of another size is rejected (`expected vector3, got vector4`).

```lua
local S = Fx.S
local Spawn = S.struct { coords = S.vector3, heading = S.number:between(0, 360) }
local _, v = Spawn:validate({ coords = { 215.4, -810.1, 30.7 }, heading = 90 })
print(v.coords.x, v.coords.z) --> 215.4 30.7
print(S.vector3:validate({ x = 1, y = 2 })) --> false z: expected number, got nil
```

### S.hash

```lua
S.hash: Schema<integer>
```

- **Notes:** accepts an integer hash as is, or a non-empty string that is hashed with `joaat` (or `GetHashKey` when `joaat` is missing). Floats and empty strings are rejected. Outside FiveM, where neither function exists, a string is returned unchanged.

```lua
local S = Fx.S
print(S.hash:is('adder'), S.hash:is(-1216765807), S.hash:is('')) --> true true false
```

### S.netId

```lua
S.netId: Schema<integer>  -- S.int:positive()
```

- **Notes:** a network id: a positive integer. It does not check that the entity exists; use `Fx.entity.fromNetId` for that ([FiveM modules](fivem-modules.md)).

```lua
print(Fx.S.netId:validate(0)) --> false must be positive
```

### S.player

```lua
S.player: Schema<integer>
```

- **Notes:** server only. An integer server id for which `GetPlayerName(tostring(id))` is not `nil`, that is, a connected player. When `GetPlayerName` does not exist (tests) it only checks `id > 0`. Failure message: `not a connected player`. On the client, `GetPlayerName` takes a player index, not a server id, so do not use this schema there.

```lua
local S = Fx.S
local Give = S.struct { target = S.player, amount = S.int:between(1, 10000) }
print(Give:is({ target = 1, amount = 50 })) --> true
print(Give:validate({ target = 99, amount = 50 })) --> false target: not a connected player
```

## Modifiers

### schema:optional()

```lua
schema:optional() -> Schema<T | nil>
```

- **Returns:** a schema that also accepts `nil` (a missing field). A missing optional field is absent from the struct output.

```lua
local S = Fx.S
local Msg = S.struct { text = S.string, color = S.string:optional() }
local _, v = Msg:validate({ text = 'hi' })
print(v.text, v.color) --> hi nil
```

### schema:default(value)

```lua
schema:default(value: T | fun(): T) -> Schema<T>
```

- **Parameters:** `value`, used when the input is `nil`. A function is called each time to produce it (use a function for table defaults, so each output gets a fresh table).
- **Notes:** the default is not validated, refined or transformed.

```lua
local S = Fx.S
local Settings = S.struct {
  volume = S.number:between(0, 1):default(0.5),
  favourites = S.array(S.string):default(function() return {} end),
}
local _, v = Settings:validate({})
print(v.volume, #v.favourites) --> 0.5 0
```

### schema:describe(text)

```lua
schema:describe(text: string) -> Schema<T>
```

- **Returns:** the same schema with a `description` field set to `text`. It does not change validation.

```lua
print(Fx.S.int:describe('Amount in dollars').description) --> Amount in dollars
```

### schema:refine(pred, message?)

```lua
schema:refine(pred: fun(value: T): (boolean, string?), message?: string) -> Schema<T>
```

- **Parameters:** `pred`, called with the decoded value after the base check passes; returns `true`, or `false` and an optional message. `message`, used when `pred` gives none.
- **Notes:** message order: the one `pred` returns, else `message`, else `failed refinement`. It is prefixed with the path. `pred` is not wrapped in `pcall`, so an error it raises propagates.

```lua
local S = Fx.S
local Plate = S.string:refine(function(p)
  if p:find('%s') then return false, 'no spaces allowed' end
  return #p <= 8
end, 'at most 8 characters')
print(Plate:validate('AB 12')) --> false no spaces allowed
print(Plate:validate('ABCDEFGHI')) --> false at most 8 characters
```

### schema:transform(fn)

```lua
schema:transform(fn: fun(value: T): U) -> Schema<U>
```

- **Parameters:** `fn`, maps the decoded value; its return value is the output. It runs in `pcall`: raising rejects the input with `tostring(err)` as the message.
- **Notes:** an error raised with `error('msg')` carries Lua's `file:line:` prefix; use `error('msg', 0)` for a clean message. Refinements added after `transform` see the transformed value.

```lua
local S = Fx.S
local Plate = S.string:transform(function(p)
  local clean = p:upper():gsub('%s', '')
  if #clean > 8 then error('plate too long', 0) end
  return clean
end)
print(Plate:validate('ab 123')) --> true AB123
print(Plate:validate('abcdefghijk')) --> false plate too long
```

## Refinements

All refinements are built on `refine` and keep the path prefix. Numeric ones need a number base (`S.number`, `S.int`); length ones need a string or table base; `pattern`, `minChars` and `maxChars` need a string base.

### schema:min(n), schema:max(n) and schema:between(lo, hi)

```lua
schema:min(n: number) -> Schema<T>          -- message: must be >= n
schema:max(n: number) -> Schema<T>          -- message: must be <= n
schema:between(lo: number, hi: number) -> Schema<T>  -- inclusive; message: must be between lo and hi
```

```lua
local S = Fx.S
print(S.int:min(18):validate(16)) --> false must be >= 18
print(S.int:between(1, 100):validate(500)) --> false must be between 1 and 100
```

### schema:positive() and schema:nonNegative()

```lua
schema:positive() -> Schema<T>     -- > 0; message: must be positive
schema:nonNegative() -> Schema<T>  -- >= 0; message: must be >= 0
```

```lua
local S = Fx.S
print(S.number:positive():is(0), S.int:nonNegative():is(0)) --> false true
```

### schema:minLen(n), schema:maxLen(n) and schema:len(n)

```lua
schema:minLen(n: integer) -> Schema<T>  -- message: length must be >= n
schema:maxLen(n: integer) -> Schema<T>  -- message: length must be <= n
schema:len(n: integer) -> Schema<T>     -- message: length must be n
```

- **Notes:** for strings the length is in **bytes** (`#s`). For tables it is the number of entries (every key counted with `pairs`, not `#t`).

```lua
local S = Fx.S
print(S.string:maxLen(3):is('héé')) --> false
print(S.string:len(4):validate('123')) --> false length must be 4
```

### schema:minItems(n), schema:maxItems(n) and schema:maxEntries(n)

```lua
schema:minItems(n: integer) -> Schema<T>    -- same as minLen
schema:maxItems(n: integer) -> Schema<T>    -- same as maxLen
schema:maxEntries(n: integer) -> Schema<T>  -- same as maxLen
```

- **Notes:** aliases that read better on arrays and records.

```lua
local S = Fx.S
print(S.array(S.int):maxItems(2):validate({ 1, 2, 3 })) --> false length must be <= 2
```

### schema:nonEmpty()

```lua
schema:nonEmpty() -> Schema<T>  -- minLen(1); message: length must be >= 1
```

```lua
print(Fx.S.string:nonEmpty():validate('')) --> false length must be >= 1
```

### schema:minChars(n) and schema:maxChars(n)

```lua
schema:minChars(n: integer) -> Schema<string>  -- message: must be at least n characters
schema:maxChars(n: integer) -> Schema<string>  -- message: must be at most n characters
```

- **Notes:** length in characters (UTF-8 code points, `utf8.len`), not bytes. Invalid UTF-8 fails. The JS side counts the same way. Prefer these for names, messages and anything a player types.

```lua
local S = Fx.S
local Name = S.string:minChars(2):maxChars(3)
print(Name:is('héé'), Name:is('h'), S.string:maxChars(10):is('\xff\xfe')) --> true false false
```

### schema:pattern(p, message?)

```lua
schema:pattern(p: string, message?: string) -> Schema<string>  -- default message: must match <p>
```

- **Parameters:** `p`, a Lua pattern (not a regular expression). Anchor it yourself with `^` and `$`; without anchors it matches anywhere in the string.

```lua
local S = Fx.S
local Plate = S.string:pattern('^%u%u%u%d%d%d$', 'plate must look like ABC123')
print(Plate:is('ABC123'), Plate:validate('abc123')) --> true false plate must look like ABC123
print(S.string:pattern('%d'):is('abc1')) --> true
```

## Schemas in tagged errors

`Fx.TaggedError(tag, fields)` takes a table of schemas and checks every instance when it is built; see [Errors](core-errors.md#fxtaggederrortag-fields).

```lua
local S = Fx.S
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney', { need = S.int })
print(pcall(NotEnoughMoney, { need = 'x' })) --> false invalid fields for NotEnoughMoney: need: expected integer, got "x"
```
