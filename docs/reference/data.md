# Data

This page covers the modules that store and read data: resource KVP (`Fx.kvp`), state bags (`Fx.state`), oxmysql (`Fx.db`) and the player, money and job API over ESX, QBCore, Qbox and standalone (`Fx.framework`). Each one checks values with a [Schema](core-schema.md) at the boundary and turns failures into tagged errors you can catch with `catchTag` ([Errors](core-errors.md)). Every function returns an effect unless noted; run it with `Fx.yield` inside `Fx.gen`, `Fx.runFork` or `Fx.runAwait` ([Effects](core-effects.md)).

| Module | Side |
|---|---|
| `Fx.kvp` | both |
| `Fx.state` | both |
| `Fx.db` | server |
| `Fx.framework` | server |

## KVP

`Fx.kvp` stores values in the resource's KVP (`SetResourceKvp`) as JSON. With a schema, values are checked on the way in and on the way out.

Error classes on `Fx.kvp`:

- `KvpInvalid { key, message }`: a write was refused (failed its schema, cannot be encoded, or would not survive JSON).
- `KvpDecodeError { key, message }`: a stored value is not valid JSON or fails its schema.

### Fx.kvp.get(key, schema)

```lua
Fx.kvp.get(key: string, schema?: Fx.Schema) -> Fx.Effect<any, KvpDecodeError>
```

- **Side:** both.
- **Parameters:** `key`; `schema`, checked against the decoded value.
- **Returns:** the decoded value (as the schema outputs it), or `nil` when the key is not set.
- **Fails with:** `KvpDecodeError` when the stored string is not JSON (`stored value is not valid JSON`) or fails the schema (the schema's message).
- **Notes:** values written with plain `SetResourceKvp` are read too, so a non-JSON string written by old code fails here.

```lua
local Prefs = S.struct { volume = S.number:between(0, 1) }
local prefs = Fx.yield(Fx.kvp.get('radio:prefs', Prefs)) or { volume = 0.5 }
```

### Fx.kvp.set(key, value, schema)

```lua
Fx.kvp.set(key: string, value: any, schema?: Fx.Schema) -> Fx.Effect<nil, KvpInvalid>
```

- **Side:** both.
- **Parameters:** `key`; `value`; `schema`, checked (and applied) before writing.
- **Returns:** `nil`.
- **Fails with:** `KvpInvalid` when:
  - the value fails `schema` (the schema's message);
  - `json.encode` fails (`value cannot be encoded as JSON`);
  - the value would come back different after a JSON round trip: tables mixing array and string keys, arrays with holes, or non-string keys (`value does not survive JSON encoding ...`).
- **Notes:** with a schema, the stored value is the schema's output, so unknown struct keys are stripped.

```lua
Fx.yield(Fx.kvp.set('radio:prefs', { volume = 0.4 }, Prefs))
Fx.yield(Fx.kvp.set('bad', { 'a', x = 1 }))   -- fails KvpInvalid: mixed keys
```

### Fx.kvp.delete(key)

```lua
Fx.kvp.delete(key: string) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** never.

```lua
Fx.yield(Fx.kvp.delete('radio:prefs'))
```

### Fx.kvp.keys(prefix)

```lua
Fx.kvp.keys(prefix: string) -> Fx.Effect<string[], never>
```

- **Side:** both.
- **Returns:** every key starting with `prefix` (full keys, prefix included), sorted. An empty list when there are none.
- **Fails with:** never.

```lua
local keys = Fx.yield(Fx.kvp.keys('garage:'))   -- { 'garage:ABC123', 'garage:XYZ789' }
```

### Fx.kvp.typed(prefix, schema)

```lua
Fx.kvp.typed(prefix: string, schema: Fx.Schema) -> Fx.KvpTyped
```

- **Side:** both.
- **Parameters:** `prefix`, prepended to every id; `schema`, used for every read and write.
- **Returns:** a `Fx.KvpTyped` store with `prefix`, `schema` and the `KvpTyped:` methods below. Not an effect.
- **Fails with:** never.

```lua
local Vehicle = S.struct { model = S.string, fuel = S.number:between(0, 100) }
local Garage = Fx.kvp.typed('garage:', Vehicle)
```

### KvpTyped:get(id)

```lua
KvpTyped:get(id: string) -> Fx.Effect<any, KvpDecodeError>
```

- **Side:** both.
- **Returns:** the value at `prefix .. id`, or `nil` when unset.
- **Fails with:** `KvpDecodeError`.

```lua
local car = Fx.yield(Garage:get('ABC123'))
```

### KvpTyped:set(id, value)

```lua
KvpTyped:set(id: string, value: any) -> Fx.Effect<nil, KvpInvalid>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** `KvpInvalid` (same rules as `Fx.kvp.set`).

```lua
Fx.yield(Garage:set('ABC123', { model = 'sultan', fuel = 64 }))
```

### KvpTyped:delete(id)

```lua
KvpTyped:delete(id: string) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** never.

```lua
Fx.yield(Garage:delete('ABC123'))
```

### KvpTyped:ids()

```lua
KvpTyped:ids() -> Fx.Effect<string[], never>
```

- **Side:** both.
- **Returns:** every stored id under the prefix, without the prefix, sorted.
- **Fails with:** never.

```lua
local plates = Fx.yield(Garage:ids())   -- { 'ABC123', 'XYZ789' }
```

### KvpTyped:all()

```lua
KvpTyped:all() -> Fx.Effect<table<string, any>, KvpDecodeError>
```

- **Side:** both.
- **Returns:** `{ [id] = value }` for every id.
- **Fails with:** `KvpDecodeError` on the first entry that does not decode. One bad entry fails the whole call.

```lua
for plate, car in pairs(Fx.yield(Garage:all())) do
  print(plate, car.model, car.fuel)
end
```

## State bags

`Fx.state` puts a schema on a state bag key. Values are checked when you set them and when a change arrives, so a handler never sees a value that fails the schema. On the server, an invalid value a client wrote to its own player or entity bag is dropped and reported as an `invalid_state` security event ([Net and RPC](net-rpc.md)).

Error classes on `Fx.state`:

- `StateInvalid { key, bag, message }`: a value failed the schema on `get` or `set`.
- `StateTimeout { key, bag, timeoutMs }`: `await` ran out of time.

A bag is a table `{ name, state }` from one of the bag functions. Bag names: `global`, `player:<serverId>`, `entity:<netId>`, `localEntity:<handle>`.

A change record passed to handlers:

```lua
---@class Fx.StateChange
---@field bag string        bag name, e.g. "player:3"
---@field value any         the new value, nil when cleared
---@field replicated boolean on the server: true when a client wrote it
---@field player? integer   for player bags
---@field entity? integer   for entity bags
```

### Fx.state.key(name, schema)

```lua
Fx.state.key(name: string, schema: Fx.Schema) -> Fx.StateKey
-- name: the state bag key
```

- **Side:** both.
- **Returns:** a `Fx.StateKey` object with `name`, `schema` and the `StateKey:` methods below. Not an effect.
- **Fails with:** never.
- **Notes:** define the same key with the same schema on both sides, ideally in a shared script.

```lua
-- shared.lua
Job = Fx.state.key('job', S.struct { name = S.string, grade = S.int })
```

### Fx.state.global()

```lua
Fx.state.global() -> Fx.StateBag
```

- **Side:** both.
- **Returns:** the `GlobalState` bag, named `global`. Not an effect.

```lua
local Weather = Fx.state.key('weather', S.literal('CLEAR', 'RAIN', 'THUNDER'))
Fx.yield(Weather:set(Fx.state.global(), 'RAIN'))
```

### Fx.state.player(src)

```lua
Fx.state.player(src?: integer) -> Fx.StateBag
-- src: server id; on the client omit it for the local player
```

- **Side:** both.
- **Returns:** the player's bag (`Player(src).state`), named `player:<src>`. On the client with no `src`, `LocalPlayer.state` with the local server id.
- **Notes:** on the server `src` is required.

```lua
Fx.yield(Job:set(Fx.state.player(src), { name = 'police', grade = 2 }))
```

### Fx.state.entity(ent)

```lua
Fx.state.entity(ent: integer) -> Fx.StateBag
-- ent: entity handle
```

- **Side:** both.
- **Returns:** `Entity(ent).state`, named `entity:<netId>` on the server or for networked entities on the client, `localEntity:<ent>` for client-only entities.

```lua
local Fuel = Fx.state.key('fuel', S.number:between(0, 100))
Fx.yield(Fuel:set(Fx.state.entity(veh), 75))
```

### StateKey:get(bag)

```lua
StateKey:get(bag: Fx.StateBag) -> Fx.Effect<any, StateInvalid>
```

- **Side:** both.
- **Returns:** the current value as the schema outputs it, or `nil` when unset.
- **Fails with:** `StateInvalid` when the bag holds a value that fails the schema.

```lua
local job = Fx.yield(Job:get(Fx.state.player()))   -- client, local player
```

### StateKey:set(bag, value, opts)

```lua
StateKey:set(bag: Fx.StateBag, value: any, opts?: { replicated?: boolean }) -> Fx.Effect<nil, StateInvalid>
```

- **Side:** both.
- **Parameters:** `value`, checked against the schema (`nil` is always allowed and clears it); `opts.replicated`, defaults to `true` on the server and `false` on the client.
- **Returns:** `nil`.
- **Fails with:** `StateInvalid` when `value` fails the schema; nothing is written.
- **Notes:** a client may only replicate to bags it owns (its own player bag, entities it controls).

```lua
local Bad = Fx.yield(Job:set(Fx.state.player(src), { name = 'police' }):exit())   -- StateInvalid: grade missing
```

### StateKey:clear(bag, opts)

```lua
StateKey:clear(bag: Fx.StateBag, opts?: { replicated?: boolean }) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`. Same as `StateKey:set(bag, nil, opts)`.
- **Fails with:** never in practice (`nil` passes the check).

```lua
Fx.yield(Job:clear(Fx.state.player(src)))
```

### StateKey:onChange(handler, opts)

```lua
StateKey:onChange(handler: fun(change: Fx.StateChange): Fx.Effect<any, any>|nil, opts?: { bag?: Fx.StateBag|string }) -> integer
-- returns: cookie for RemoveStateBagChangeHandler
```

- **Side:** both.
- **Parameters:** `handler`, called for every valid change of the key; `opts.bag`, a bag or a bag name to listen to one bag only.
- **Returns:** the cookie from `AddStateBagChangeHandler`. Not an effect; the handler is registered right away.
- **Fails with:** never. A handler that raises is reported as a defect.
- **Notes:**
  - A cleared value (`nil`) is a valid change; `change.value` is `nil`.
  - If `handler` returns an effect, it runs on its own fiber.
  - An invalid value never reaches the handler. On the server, if a client wrote it (`replicated` is true), it is reported with `Fx.security.report { kind = 'invalid_state', source, name, message, bag }`. `source` is the player for player bags and the entity owner for entity bags. On the client invalid values are dropped silently.
  - Handlers also end when the resource stops.

```lua
-- client
Job:onChange(function(change)
  Hud.setJob(change.value and change.value.name or 'unemployed')
end, { bag = Fx.state.player() })
```

### StateKey:watch(handler, opts)

```lua
StateKey:watch(handler: fun(change: Fx.StateChange): Fx.Effect<any, any>|nil, opts?: { bag?: Fx.StateBag|string }) -> Fx.Effect<nil, never>
-- requires Scope
```

- **Side:** both.
- **Returns:** `nil`. The handler is registered when the effect runs and removed when the scope closes.
- **Fails with:** never.

```lua
Fx.runFork(Fx.player.extend(src, Job:watch(function(c)
  print(('player %s is now %s'):format(c.player, c.value and c.value.name))
end, { bag = Fx.state.player(src) })))
```

### StateKey:await(bag, predicate, opts)

```lua
StateKey:await(bag: Fx.StateBag, predicate?: fun(value: any): boolean, opts?: { timeout?: integer }) -> Fx.Effect<any, StateTimeout>
-- predicate: default: value ~= nil
```

- **Side:** both.
- **Returns:** the first valid value (current or future) for which `predicate` is true.
- **Fails with:** `StateTimeout` when `opts.timeout` is set and runs out. Without a timeout it waits forever.
- **Notes:** checks the current value first. If it is invalid or does not match, it waits for changes on that bag. Interrupting it removes the handler.

```lua
local Ready = Fx.state.key('ready', S.boolean)
Fx.yield(Ready:await(Fx.state.global(), nil, { timeout = 10000 }))
```

### StateKey:changes(opts)

```lua
StateKey:changes(opts?: { bag?: Fx.StateBag|string, buffer?: integer, strategy?: 'sliding'|'dropping' }) -> Fx.Stream<Fx.StateChange>
```

- **Side:** both.
- **Parameters:** `opts.bag` as in `onChange`; `opts.buffer` (default 1024) and `opts.strategy` (default `sliding`, drops the oldest; `dropping` keeps the oldest) as in `Fx.Stream.async`.
- **Returns:** a [stream](streams.md) of valid change records. The handler is registered while the stream runs and removed when it ends.
- **Fails with:** never.

```lua
-- client: react to job changes, but not to every flicker
Fx.runFork(Job:changes({ bag = Fx.state.player() })
  :debounce(250)
  :runForEach(function(change) return Hud.setJob(change.value) end))
```

## Database

`Fx.db` runs oxmysql queries as effects. Every failure is a `SqlError`, and a row that fails its schema is a `SqlDecodeError`, so you can catch, retry or map them. Queries go to oxmysql unless an `Fx.db.Database` service is provided.

Error classes on `Fx.db`:

- `SqlError { method, sql, message }`: the driver reported an error. For `transaction`, `sql` is absent. `message` is the database's line: FiveM's "An error occurred while calling export" wrapping and oxmysql's query dump are stripped, as are `^1`-style colour codes.
- `SqlDecodeError { sql, index, message }`: row `index` (1-based) failed `opts.row`, or the scalar failed `opts.value` (`index` is 1).

### Fx.db.query(sql, params, opts)

```lua
Fx.db.query(sql: string, params?: table, opts?: { row?: Fx.Schema }) -> Fx.Effect<table[], SqlError|SqlDecodeError>
```

- **Side:** server.
- **Parameters:** `params`, positional (`?`) or named, as oxmysql takes them; `opts.row`, checked against every row.
- **Returns:** the rows (an empty table when there are none), as the schema outputs them.
- **Fails with:** `SqlError`; `SqlDecodeError` on the first row that fails `opts.row`.

```lua
local Row = S.struct { id = S.int, name = S.string, money = S.int }
local rich = Fx.yield(Fx.db.query('SELECT id, name, money FROM players WHERE money > ?', { 100000 }, { row = Row })
  :retry(Fx.Schedule.exponential(100):take(3)))
```

### Fx.db.single(sql, params, opts)

```lua
Fx.db.single(sql: string, params?: table, opts?: { row?: Fx.Schema }) -> Fx.Effect<table|nil, SqlError|SqlDecodeError>
```

- **Side:** server.
- **Returns:** the first row, or `nil` when there is none (not an error).
- **Fails with:** `SqlError`; `SqlDecodeError` when the row fails `opts.row`.

```lua
local NotYours = Fx.TaggedError('NotYours')

local owner = Fx.yield(Fx.db.single('SELECT owner, garage FROM owned_vehicles WHERE plate = ?', { plate },
  { row = S.struct { owner = S.string, garage = S.string } }))
if not owner then Fx.yield(NotYours { plate = plate }:fail()) end
```

### Fx.db.scalar(sql, params, opts)

```lua
Fx.db.scalar(sql: string, params?: table, opts?: { value?: Fx.Schema }) -> Fx.Effect<any, SqlError|SqlDecodeError>
```

- **Side:** server.
- **Parameters:** `opts.value`, checked against the value (note: `value`, not `row`).
- **Returns:** the first column of the first row, or `nil`.
- **Fails with:** `SqlError`; `SqlDecodeError { index = 1 }` when the value fails `opts.value`.

```lua
local count = Fx.yield(Fx.db.scalar('SELECT COUNT(*) FROM owned_vehicles WHERE owner = ?', { cid }, { value = S.int }))
```

### Fx.db.insert(sql, params)

```lua
Fx.db.insert(sql: string, params?: table) -> Fx.Effect<integer, SqlError>
```

- **Side:** server.
- **Returns:** the new row's id.
- **Fails with:** `SqlError`.

```lua
local id = Fx.yield(Fx.db.insert('INSERT INTO bank_logs (cid, amount, reason) VALUES (?, ?, ?)', { cid, 500, 'garage fee' }))
```

### Fx.db.update(sql, params)

```lua
Fx.db.update(sql: string, params?: table) -> Fx.Effect<integer, SqlError>
```

- **Side:** server.
- **Returns:** the number of affected rows.
- **Fails with:** `SqlError`.

```lua
local n = Fx.yield(Fx.db.update('UPDATE owned_vehicles SET garage = ? WHERE plate = ?', { 'pillbox', plate }))
```

### Fx.db.prepare(sql, params)

```lua
Fx.db.prepare(sql: string, params?: table) -> Fx.Effect<any, SqlError>
```

- **Side:** server.
- **Parameters:** `params`, one parameter set or a list of sets, as oxmysql's `prepare` takes them.
- **Returns:** what oxmysql's `prepare` returns.
- **Fails with:** `SqlError`.

```lua
Fx.yield(Fx.db.prepare('UPDATE players SET last_seen = NOW() WHERE cid = ?', { { 'ABC123' }, { 'XYZ789' } }))
```

### Fx.db.transaction(queries, params)

```lua
Fx.db.transaction(queries: table, params?: table) -> Fx.Effect<true, SqlError>
-- queries: list of { query = sql, values = params }, or sql strings with shared params
-- params: shared params
```

- **Side:** server.
- **Returns:** `true` when committed.
- **Fails with:** `SqlError { method = 'transaction' }` when the driver reports an error, or with message `transaction rolled back` when it answers `false` or `nil`.

```lua
Fx.yield(Fx.db.transaction({
  { query = 'UPDATE players SET money = money - ? WHERE cid = ?', values = { price, cid } },
  { query = 'INSERT INTO owned_vehicles (owner, plate, model) VALUES (?, ?, ?)', values = { cid, plate, model } },
}))
```

### Fx.db.Database

```lua
---@type Fx.Tag  key 'rivo_fx/Database'
Fx.db.Database

---@alias Fx.DbDone fun(result: any, err?: any)
---@class Fx.DbDriver
---@field query fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field single fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field scalar fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field insert fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field update fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field prepare fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field transaction fun(queries: table, params: table|nil, done: Fx.DbDone)
```

- **Side:** server.
- **Notes:**
  - The service tag for the driver. Every `Fx.db` call looks it up with `Fx.serviceOption`; when it is not provided, the live driver `Fx.db.oxmysql` is used.
  - A provided driver replaces oxmysql entirely: a method it does not implement raises when called (a defect, not a `SqlError`).
  - Each method calls `done(result)` on success or `done(nil, err)` on failure. Any `err` other than `nil` and `false` becomes a `SqlError`; a table `err` uses `err.message` or `err.error`.
  - `params` is passed as given (it may be `nil`); the oxmysql driver turns `nil` into `{}`.
  - `Fx.db.oxmysql` is the live driver table and `Fx.db.layer` is `Fx.Layer.succeed(Fx.db.Database, Fx.db.oxmysql)`, for providing it explicitly.

```lua
-- a fake database for tests
local Fake = Fx.Layer.succeed(Fx.db.Database, {
  query = function(sql, params, done) done({ { id = 1, name = 'Vex', money = 500 } }) end,
  scalar = function(sql, params, done) done(nil, 'connection lost') end,
})

local rows = Fx.yield(Fx.db.query('SELECT id, name, money FROM players'):provide(Fake))
```

## Framework

`Fx.framework` gives one player, money and job API over ESX, QBCore, Qbox and standalone. You get it as the `Framework` service from a layer and read it with `Fx.yield(Fx.framework.Framework)` ([Services and layers](core-resources.md)).

Error classes on `Fx.framework`:

- `PlayerNotFound { source }`: no player (or no character loaded) for that id.
- `InsufficientFunds { source, account, need, have }`: `removeMoney` would go negative, or the framework refused the removal.
- `FrameworkError { message }`: an unknown account, a bad amount, a job or grade that does not exist, the framework refusing to add money, or the framework's lookup raising.

Shapes:

```lua
---@class Fx.FrameworkJob
---@field name string
---@field label? string
---@field grade? integer
---@field gradeLabel? string

---@class Fx.FrameworkPlayer
---@field source integer
---@field identifier string  ESX: identifier, QBCore/Qbox: citizenid, standalone: license identifier
---@field name string        ESX: getName(), QBCore/Qbox: charinfo first + last name (else the player name), standalone: player name
---@field job Fx.FrameworkJob standalone: { name = 'unemployed', label = 'Unemployed', grade = 0, gradeLabel = 'Unemployed' }
---@field money { cash: number, bank: number } ESX 'money' account is cash

---@alias Fx.MoneyAccount 'cash'|'bank'
```

The player table is a snapshot taken when you ask; read money again with `getMoney`.

### Fx.framework.auto

```lua
---@type Fx.Layer  provides Fx.framework.Framework
Fx.framework.auto
```

- **Side:** server.
- **Notes:** picks the framework with `Fx.framework.detect()` when the layer is built. The service for each framework is built once per resource and shared by every layer that provides it (building it registers event handlers).

```lua
Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('garage:pay', { input = S.struct {} }, function(src)
  return Fx.gen(function()
    local fw = Fx.yield(Fx.framework.Framework)
    return Fx.yield(fw.removeMoney(src, 'bank', 500, 'garage fee'))
  end)
end)
```

### Fx.framework.esx, qbcore, qbox, standalone

```lua
---@type Fx.Layer
Fx.framework.esx         -- exports.es_extended:getSharedObject()
Fx.framework.qbcore      -- exports['qb-core']:GetCoreObject()
Fx.framework.qbox        -- exports.qbx_core
Fx.framework.standalone  -- no framework
```

- **Side:** server.
- **Notes:**
  - Use one to force a framework instead of detecting it.
  - Standalone has no characters: every connected player is a player, money lives in memory per session (starts at 0 cash and 0 bank, gone on drop), the job is always `unemployed`, `setJob` always fails with `FrameworkError`, and there are no job change events.

```lua
Fx.setRuntime(Fx.Runtime.make(Fx.framework.qbox))
```

### Fx.framework.detect()

```lua
Fx.framework.detect() -> 'qbox'|'qbcore'|'esx'|'standalone'
```

- **Side:** server.
- **Returns:** the first started resource among `qbx_core` (qbox), `qb-core` (qbcore), `es_extended` (esx); else `standalone`. Not an effect.
- **Notes:** Qbox is checked before QBCore.

```lua
print('framework: ' .. Fx.framework.detect())
```

### Fx.framework.Framework

```lua
---@type Fx.Tag  key 'rivo_fx/Framework'
Fx.framework.Framework
```

- **Side:** server.
- **Returns:** as an effect (`Fx.yield(Fx.framework.Framework)`), the service with `name` (`'esx'|'qbcore'|'qbox'|'standalone'`) and the methods below.
- **Fails with:** dies with `Service not found: rivo_fx/Framework` when no framework layer is provided.

```lua
local fw = Fx.yield(Fx.framework.Framework)
print(fw.name)
```

### fw.getPlayer(src)

```lua
fw.getPlayer(src: integer) -> Fx.Effect<Fx.FrameworkPlayer, PlayerNotFound|FrameworkError>
```

- **Side:** server.
- **Returns:** the normalized player.
- **Fails with:** `PlayerNotFound` when there is no player or character; `FrameworkError` when the framework's lookup raises.

```lua
local p = Fx.yield(fw.getPlayer(src))
print(p.name, p.job.name, p.money.bank)
```

### fw.findPlayer(src)

```lua
fw.findPlayer(src: integer) -> Fx.Effect<Fx.FrameworkPlayer|nil, FrameworkError>
```

- **Side:** server.
- **Returns:** the player, or `nil` when they have no character loaded.
- **Fails with:** `FrameworkError`.

```lua
local p = Fx.yield(fw.findPlayer(src))
if not p then return Fx.succeed(nil) end
```

### fw.getMoney(src, account)

```lua
fw.getMoney(src: integer, account: 'cash'|'bank') -> Fx.Effect<number, PlayerNotFound|FrameworkError>
```

- **Side:** server.
- **Returns:** the live balance (read from the framework each time, not from a copy).
- **Fails with:** `FrameworkError` for any account other than `cash` or `bank`; `PlayerNotFound`.

```lua
local cash = Fx.yield(fw.getMoney(src, 'cash'))
```

### fw.addMoney(src, account, amount, reason)

```lua
fw.addMoney(src: integer, account: 'cash'|'bank', amount: number, reason?: string) -> Fx.Effect<number, PlayerNotFound|FrameworkError>
-- reason: default: the resource name
```

- **Side:** server.
- **Parameters:** `amount` must be a number, at least 0, not NaN and not infinite.
- **Returns:** the new balance.
- **Fails with:** `FrameworkError` for a bad account or amount, or `the framework refused to add money` when the framework's add returns `false`; `PlayerNotFound`.
- **Notes:** ESX's `addAccountMoney` returns nothing, so a refusal is not detected on ESX.

```lua
local bank = Fx.yield(fw.addMoney(src, 'bank', 2500, 'paycheck'))
```

### fw.removeMoney(src, account, amount, reason)

```lua
fw.removeMoney(src: integer, account: 'cash'|'bank', amount: number, reason?: string) -> Fx.Effect<number, InsufficientFunds|PlayerNotFound|FrameworkError>
-- reason: default: the resource name
```

- **Side:** server.
- **Returns:** the new balance.
- **Fails with:** `InsufficientFunds { source, account, need, have }` when the balance is below `amount` (nothing is removed) or when the framework's remove returns `false`; `FrameworkError` for a bad account or amount; `PlayerNotFound`.

```lua
Fx.yield(fw.removeMoney(src, 'bank', price, 'vehicle purchase')
  :catchTag('InsufficientFunds', function(e)
    return Fx.net.emit('shop:notify', src, { text = ('You need $%d more'):format(e.need - e.have) })
  end))
```

### fw.setJob(src, job, grade)

```lua
fw.setJob(src: integer, job: string, grade?: integer) -> Fx.Effect<Fx.FrameworkJob, PlayerNotFound|FrameworkError>
-- grade: default 0
```

- **Side:** server.
- **Returns:** the player's job after the change.
- **Fails with:** `FrameworkError` (`job <job> grade <grade> does not exist in <framework>`) when the job or grade does not exist, and always on standalone; `PlayerNotFound`.
- **Notes:** ESX checks `ESX.DoesJobExist(job, tostring(grade))` first. QBCore calls `Functions.SetJob(job, tostring(grade))`; Qbox calls `exports.qbx_core:SetJob(src, job, grade)`.

```lua
local job = Fx.yield(fw.setJob(src, 'police', 1))
print(job.label, job.gradeLabel)
```

### fw.onPlayerLoaded(fn)

```lua
fw.onPlayerLoaded(fn: fun(src: integer): Fx.Effect<any, any>|nil) -> fun()
-- returns: removes the handler
```

- **Side:** server.
- **Returns:** a function that removes the handler. Not an effect.
- **Notes:**
  - Fires when a character is loaded: `esx:playerLoaded`, `QBCore:Server:PlayerLoaded` (QBCore and Qbox), `playerJoining` (standalone).
  - Players who already had a character when the service was built do not get a loaded event, but are tracked so their unload still fires.
  - If `fn` returns an effect, it runs on its own fiber. A handler that raises is reported as a defect.

```lua
fw.onPlayerLoaded(function(src)
  return fw.getPlayer(src):flatMap(function(p)
    return Fx.logInfo('character loaded', { player = src, cid = p.identifier })
  end)
end)
```

### fw.onPlayerUnloaded(fn)

```lua
fw.onPlayerUnloaded(fn: fun(src: integer): Fx.Effect<any, any>|nil) -> fun()
-- returns: removes the handler
```

- **Side:** server.
- **Returns:** a function that removes the handler.
- **Notes:** fires exactly once per loaded character, on logout (`esx:playerDropped`, `QBCore:Server:OnPlayerUnload`) or on `playerDropped`, whichever comes first and whatever order resources handle the drop in.

```lua
fw.onPlayerUnloaded(function(src) activeDuty[src] = nil end)
```

### fw.onJobChange(fn)

```lua
fw.onJobChange(fn: fun(src: integer, job: Fx.FrameworkJob): Fx.Effect<any, any>|nil) -> fun()
-- returns: removes the handler
```

- **Side:** server.
- **Returns:** a function that removes the handler.
- **Notes:** fires on `esx:setJob` or `QBCore:Server:OnJobUpdate` (QBCore and Qbox) with the normalized job. Never fires on standalone.

```lua
fw.onJobChange(function(src, job)
  return Job:set(Fx.state.player(src), { name = job.name, grade = job.grade or 0 })
end)
```
