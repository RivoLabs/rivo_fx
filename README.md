# Rivo FX

Effect-style typed systems for FiveM. Rivo FX gives Lua and JS/TS resources the
model [Effect](https://effect.website) made popular: errors as values, fibers
that clean up after themselves, services through Layers, and Schema at every
trust boundary. On top of that it adds the FiveM pieces scripts get wrong most
often:

- **Net events that validate first.** A handler never sees a payload that
  fails its schema, and every player is rate limited per event by default.
- **RPC with timeouts and typed errors.** A `NotEnoughMoney` raised on the
  server arrives on the client as `NotEnoughMoney`, so `catchTag` works across
  the wire. Defects never leak details to clients.
- **Cleanup that actually runs.** Scopes close when the resource stops or the
  player drops. Spawned entities get deleted, models released and in-flight
  handlers interrupted.
- **No more `while not HasModelLoaded(m) do Wait(0) end`.** Asset loads have
  timeouts and typed errors.

Free and MIT licensed. Lua 5.4, FiveM. In-game devtools (`/fxdev`), metrics
and tracing included.

## Install

1. Download `rivo_fx.zip` from the [latest release](https://github.com/RivoLabs/rivo_fx/releases/latest),
   unzip it into your resources folder (the folder must be named `rivo_fx`) and
   `ensure rivo_fx` before anything that uses it.
2. In your resource:

```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

The library loads into your resource's own runtime, the way `ox_lib` does. No
exports sit on the hot path, and FiveM modules load on first use.

**Types:** add `rivo_fx/types` to your LuaLS library:

```json
{ "workspace.library": ["../rivo_fx/types"] }
```

## A taste

```lua
local S = Fx.S
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

-- a service, provided by a Layer
local Bank = Fx.Tag('Bank')
local BankLive = Fx.Layer.succeed(Bank, {
  withdraw = function(src, amount)
    return Fx.suspend(function()
      local have = balances[src] or 0
      if have < amount then return NotEnoughMoney { have = have, need = amount }:fail() end
      balances[src] = have - amount
      return Fx.succeed(balances[src])
    end)
  end,
})
Fx.setRuntime(Fx.Runtime.make(BankLive))

-- server: validated, rate limited, typed
Fx.rpc.register('bank:withdraw', { input = S.struct { amount = S.int:between(1, 1e6) } },
  function(src, input)
    return Fx.gen(function()
      local bank = Fx.yield(Bank)
      return Fx.yield(bank.withdraw(src, input.amount))
    end)
  end)
```

```lua
-- client
Fx.runFork(Fx.gen(function()
  local balance = Fx.yield(
    Fx.rpc.call('bank:withdraw', { amount = 500 }, { timeout = 5000 })
      :catchTag('NotEnoughMoney', function(e)
        return Fx.succeed(e.have)
      end)
  )
  print('balance now', balance)
end))
```

## Start a resource

```sh
npx rivo-fx create my_shop                      # server + client
npx rivo-fx create my_shop --template lua-nui   # plus a page using @rivolabs/fx-nui
```

Moving an existing resource over? [docs/MIGRATING.md](docs/MIGRATING.md) has
before/after code for net events, ox_lib/ESX/QBCore callbacks, framework money,
oxmysql, asset loading, threads and NUI.

## Level 0: use it without learning Effect

Already have a codebase? Start with `Fx.runAwait`. It runs an effect from any
Citizen thread and returns the value, or raises the error so `pcall` works:

```lua
CreateThread(function()
  local hash = Fx.runAwait(Fx.assets.model('adder', { timeout = 5000 }))
  -- ... spawn something
end)
```

## Core

| | |
|---|---|
| `Fx.succeed / fail / die / sync / try / suspend / async` | build effects |
| `:map :flatMap :andThen :tap :zip` | chain |
| `:catchAll :catchTag :catchTags :mapError :orElse :result :option` | handle errors |
| `Fx.gen(function() local x = Fx.yield(eff) end)` | direct style (`eff:await()` also works inside a gen) |
| `:timeout(ms) :retry(policy) :repeatWith(schedule) :delay(ms)` | time |
| `Fx.Schedule.exponential(100):take(5):jittered()` | retry and repeat schedules |
| `:fork :forkDaemon :forkScoped`, `Fx.forEach(list, f, { concurrency = 4 })`, `Fx.all`, `:race` | concurrency |
| `Fx.Tag`, `Fx.serviceOption(tag)`, `Fx.Layer.succeed/effect/scoped/merge`, `:provide(layer)`, `Fx.Runtime.make(layer)` | services |
| `Fx.scoped`, `Fx.acquireRelease`, `Fx.addFinalizer`, `:ensuring`, `:onExit` | resources |
| `Fx.Ref`, `Fx.Deferred`, `Fx.Semaphore`, `Fx.Queue`, `Fx.PubSub` | shared state |
| `Fx.Stream` | values over time (see [Streams](#streams)) |
| `Fx.S.*` | Schema |
| `Fx.TaggedError('Name')` | typed errors |
| `Fx.runFork / runAwait / runSync / runCallback` | run |

Inside `Fx.gen`, `Citizen.Wait` and `Citizen.Await` still work. Raising a
tagged error with `error(NotFound {})` fails the effect with that error. Any
other raised error is a defect.

**How fibers run.** A fiber is a coroutine on a runner inside your resource,
not a Citizen thread, so a parked fiber costs nothing and waking one is a
plain `coroutine.resume`. Timers share one thread per resource, which sleeps
until the next one is due. Code in a fiber that calls `Wait` or
`Citizen.Await` (in `Fx.gen` or plain `Fx.sync` code) borrows a Citizen
thread for that wait and behaves exactly as it would on its own thread.
Prefer `Fx.sleep` over `Wait` inside fibers: it stays on the runner and can
be interrupted. A fiber woken by another fiber (a `Queue` offer, a
`Deferred`) runs once the waker parks or yields, not in the middle of it.

## Streams

A stream is a description of values over time: game events, net events,
state bag changes, security events, ticks. Like an effect, nothing runs until
you run it, and stopping it (`take`, an interrupted fiber, a closed scope)
removes the event handlers it registered.

```lua
-- Post bad payloads to a webhook in batches: a post goes out once 20 have
-- piled up, or 10 s after the first of a batch, whichever comes first.
Fx.runFork(Fx.security.stream()
  :filter(function(ev) return ev.kind ~= 'rate_limited' end)
  :groupedWithin(20, 10000)
  :runForEach(function(batch) return Webhook.post(batch) end))

-- A net event as a stream, with the same schema and rate limit as Fx.net.handle.
Fx.runFork(Fx.net.stream('radio:join', S.struct { channel = S.int:between(1, 999) })
  :runForEach(function(m) return Radio.join(m.source, m.input.channel) end))

-- Client: react to a job change, but not to every flicker.
Fx.runFork(Job:changes({ bag = Fx.state.player() })
  :debounce(250)
  :runForEach(function(change) return Hud.setJob(change.value) end))
```

| | |
|---|---|
| Sources | `Stream.make(...)`, `fromTable`, `range`, `iterate`, `fromEffect`, `repeatEffect`, `interval(ms)`, `fromSchedule`, `fromQueue`, `fromPubSub`, `async(register, { buffer })`, `event(name, shape?)`, `merge(...)`; FiveM: `Fx.net.stream`, `Key:changes`, `Fx.security.stream` |
| Operators | `map`, `mapEffect`, `filter`, `filterMap`, `tap`, `take`, `takeWhile`, `takeUntil`, `drop`, `dropWhile`, `scan`, `changes`, `grouped`, `groupedWithin`, `debounce`, `throttle`, `flatMap`, `concat`, `merge`, `catchAll`, `ensuring`, `interruptAfter` |
| Running | `runForEach`, `runForEachWhile`, `runCollect`, `runDrain`, `runFold`, `runCount`, `runHead`, `runLast`, `runFork` |

Values pushed from callbacks wait in a buffer while the consumer is busy
(1024 by default). When the buffer is full, the oldest value is dropped. Pass
`{ buffer = n, strategy = 'dropping' }` to keep the oldest instead. Each
value moves through the stream one at a time and in order. A slow
`runForEach` slows the stream down; it never runs two values at once.

## Metrics and tracing

Wrap an effect in a span to see where its time goes and how it failed. Spans
nest, follow forked fibers, and cross `Fx.rpc` calls: a client's call and the
server handler it reaches share one trace, in Lua and in JS.

```lua
local Deposits = Fx.metrics.counter('bank_deposits_total', { help = 'Deposits made' })
local Latency = Fx.metrics.histogram('bank_deposit_ms', { buckets = { 5, 25, 100, 500 } })

local function deposit(src, amount)
  return Bank.credit(src, amount)
    :tap(function() Deposits:inc(1, { account = 'main' }) end)
    :trackDuration(Latency)
    :withSpan('bank.deposit', { attributes = { amount = amount } })
end
```

| | |
|---|---|
| Spans | `eff:withSpan(name, { attributes, kind, parent, root })`, `Fx.span(name, fn)`, `Fx.currentSpan`, `Fx.annotateCurrentSpan(k, v)`; finished spans in `Fx.trace.on(fn)`, `Fx.trace.stream()`, `Fx.trace.recent()` |
| Metrics | `Fx.metrics.counter / gauge / histogram(name, { help, buckets })` with `inc`, `set`, `add`, `observe` and optional labels; `eff:trackDuration(histogram)`, `eff:trackErrors(counter)`; `Fx.metrics.snapshot()`, `Fx.metrics.prometheus()` |
| Built in | a span per `Fx.rpc` call and handler, and per `Fx.net.handle` effect; `rivo_fx_rpc_handler_ms`, `rivo_fx_rpc_call_ms`, `rivo_fx_net_events_total`, `rivo_fx_security_events_total`, `rivo_fx_fibers`, `rivo_fx_timers` |

Effect logs (`Fx.logInfo`, ...) carry `traceId` and `spanId`, so a log line
leads to its trace. A label set that grows past 1000 series per metric (a
player id as a label, say) stops adding series instead of eating memory.
`set rivo_fx:tracing off` stops recording spans.

**Scraping.** The `rivo_fx` resource serves every resource's metrics, merged
and labelled by `resource`, at `http://<server>:30120/rivo_fx/metrics`, and
the latest spans as JSON at `/rivo_fx/spans?limit=100`. Both are off until
you set a token, and each request must send it:

```cfg
set rivo_fx:metricsToken "a-long-random-string"   # set, not setr: keep it off clients
```

```yaml
# prometheus.yml
scrape_configs:
  - job_name: fivem
    metrics_path: /rivo_fx/metrics
    authorization: { credentials: a-long-random-string }
    static_configs: [{ targets: ['your-server:30120'] }]
```

## Devtools

Type `/fxdev` in game for a live view of every resource that uses Rivo FX,
on the server and on your own client:

| View | Shows |
|---|---|
| Overview | each resource with its live fibers, timers, finished spans, failures and the last failure |
| Fibers | the fibers alive right now, children under their parent, with status, age and the span each one is in |
| Traces | recent traces as a waterfall; a client's `Fx.rpc` call and the server handler it reached are one trace |
| Failures | error logs, unhandled fiber failures and defects, with the full cause and a link to the trace |
| Metrics | every metric and label set; histograms with count, average, p50, p95 and p99 |

`/fxdev traces` (or any view) opens straight on that view. Filter by resource
or name (`/`), show one side only, pause, or switch between the dark and light
theme. Busy servers stay readable: the busiest resources come first, fibers
fold per resource, a failure that repeats is one row with a count, and long
lists stop at a sensible length until you ask for all.

Only players with the `rivo_fx.devtools` ACE can open it; the server checks
every request:

```cfg
add_ace group.admin rivo_fx.devtools allow
```

Spans and failures can hold player ids and error details, so give it to the
people who can already read your server console. It asks for data once a
second while open (less often when collecting gets expensive, up to every
5 s) and not at all when closed.

## FiveM modules

| Module | What it does |
|---|---|
| `Fx.net` | `handle(name, schema, handler, { rateLimit = '10/s' })`, `stream(name, schema)`, `send`, `broadcast`, `emit` |
| `Fx.rpc` | `register(name, { input, output?, rateLimit? }, handler)`, `call(name, input, { timeout })` (client), `callClient(player, name, input)` (server) |
| `Fx.security` | `on(fn)` or `stream()` for `invalid_payload`, `rate_limited`, `unknown_rpc` and `invalid_state`, also fired as the `rivo_fx:security` event |
| `Fx.player` | `scope(src)`, `fork(src, eff)`, `onDrop(src, fn)`: tied to the player's session |
| `Fx.onStop(fn)`, `Fx.resourceScope` | resource lifecycle; every open scope closes on stop |
| `Fx.config` | typed convars (`int`, `bool`, `enum`, `json`, ...) and config files |
| `Fx.log`, `Fx.logInfo(...)` | levelled logs, level from the `rivo_fx:logLevel` convar |
| `Fx.assets` | `model`, `animDict`, `animSet`, `ptfx`, `textureDict`, `scaleform`, `audioBank`, each with a scoped `use*` variant |
| `Fx.entity` | `exists`, `requestControl`, `fromNetId`, scoped `spawnVehicle/Ped/Object` |
| `Fx.kvp` | typed resource KVP: `get(key, schema)`, `set`, `keys(prefix)`, `typed(prefix, schema)` with `get/set/delete/ids/all`; refuses values JSON would corrupt |
| `Fx.state` | schema-typed state bag keys: `key(name, schema)` with `get/set/clear/onChange/watch/await/changes` on `global()`, `player(src)`, `entity(ent)`; invalid client writes become `invalid_state` security events |
| `Fx.db` | oxmysql as typed effects (server): `query(sql, params, { row = schema })`, `single`, `scalar`, `insert`, `update`, `prepare`, `transaction`; failures are `SqlError` / `SqlDecodeError`; swap the driver with the `Fx.db.Database` service |
| `Fx.framework` | one player/money/job API over ESX, QBCore, Qbox and standalone (server): the `Framework` service from `Fx.framework.auto` (or `.esx`/`.qbcore`/`.qbox`/`.standalone`) with `getPlayer`, `getMoney`, `addMoney`, `removeMoney` (fails `InsufficientFunds`), `setJob`, `onPlayerLoaded/Unloaded`, `onJobChange` |
| `Fx.nui` | typed NUI (client): `handle(name, { input, output? }, fn)` answers the page's fetch with `{ ok, value }` or a typed error (`NuiInvalidInput`, your tagged errors, `NuiInternalError` without details); `send(type, payload, schema?)`; scoped `useFocus()`. The page side is [`@rivolabs/fx-nui`](packages/fx-nui) |
| `Fx.tick` | frame-bound work that stops cleanly: `everyFrame(fn)`, `whileNear(coords, radius, fn)`, `whileTrue(cond, fn)` |
| `Fx.compat` | ox_lib bridge: `spec.libCallback = true` on `Fx.rpc.register`, `Fx.compat.libCallback(name, ...)` |

The wire protocol (shared by the Lua and JS implementations) is in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## JS / TS

[`packages/fx`](packages/fx) is `@rivolabs/fx`: FiveM adapters for the real
[`effect`](https://effect.website) package, speaking the same protocol. A Lua
client can call a TypeScript server RPC and the other way round.

```sh
npm install @rivolabs/fx effect
```

## NUI pages

[`packages/fx-nui`](packages/fx-nui) is `@rivolabs/fx-nui`, a dependency-free (about
3 KB) helper for the page, in any framework:

```ts
import { fetchNui, onMessage, isNuiError } from "@rivolabs/fx-nui"

try {
  const { bought } = await fetchNui<{ bought: string }>("buy", { item: "apple", qty: 2 })
} catch (e) {
  if (isNuiError(e, "OutOfStock")) showSoldOut()
}
onMessage<{ items: string[] }>("open", ({ items }) => render(items))
```

Outside the game, `mockNui(name, fn)` answers calls so the page runs in a normal
browser.

## One schema, every side

[`packages/cli`](packages/cli) is `rivo-fx`. Describe payloads once in a JSON
schema file and generate the Lua validators (with LuaLS types), the Effect
schemas for JS resources and the plain types for NUI pages:

```sh
npx rivo-fx gen shared/shop.schema.json --lua shared/schemas.lua --ts src/schemas.ts --types web/src/schemas.ts
```

## Development

```sh
lua5.4 tests/run.lua                                      # unit tests (virtual clock)
lua5.4 tests/bench.lua                                    # benchmarks
lua-language-server --check . --checklevel=Information    # types/ and examples
cd packages/fx && pnpm install && pnpm test               # the JS package (also fx-nui, cli)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and
[CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## What's next

- OpenTelemetry (OTLP) export of spans and metrics
- A layer graph view in `/fxdev`
- An ox_core framework layer
- A TypeScript resource template for `rivo-fx create`
