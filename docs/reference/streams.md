# Streams

`Fx.Stream` describes zero or more values over time: game events, net events, state bag changes, security events, timers, queues. This page covers every source, operator and runner, plus the FiveM sources `Fx.net.stream`, `StateKey:changes` and `Fx.security.stream`. Use a stream when you would otherwise write an event handler with hand-rolled batching, debouncing, cleanup or rate limiting. For a single value use an effect instead ([Effects](core-effects.md)).

## How streams run

A stream is a description. Nothing happens until you run it with one of the `run*` methods, which return an effect, and that effect runs on a fiber like any other (`Fx.runFork`, `Fx.yield`, `Fx.runAwait`). Running the same stream twice runs it twice from the start, with its own handlers and buffers.

```lua
local s = Fx.Stream.range(1, 3):map(function(x) return x * 10 end)
Fx.runFork(s:runForEach(print))   -- prints 10, 20, 30
Fx.runFork(s:runForEach(print))   -- runs again from the start: 10, 20, 30
```

Values may be `nil`. A `nil` value is still a value: it is counted, passed to callbacks, and leaves a hole in `runCollect`'s list.

### Ordering

- Each value goes through the whole pipeline, including the effect returned by your `runForEach` callback, before the next value is taken. A stream never handles two values at once. `mapEffect` and `tap` run their effects one at a time, in order.
- Values keep the order their source produced them in. The one exception is `merge`, which interleaves several sources by arrival time (each source keeps its own order).
- A slow consumer slows the stream down. What happens to values that arrive meanwhile depends on the source (next section).

### Back-pressure and buffers

| Source or operator | While the consumer is busy |
|---|---|
| `make`, `fromTable`, `range`, `iterate`, `fromEffect`, `repeatEffect` | Nothing is produced. The next value is computed only when the consumer asks for it. |
| `interval`, `fromSchedule` | The next wait starts after the consumer has handled the previous value, so a slow consumer stretches the period. |
| `fromQueue` | Values wait in the queue, under the queue's own capacity and strategy ([Concurrency](core-concurrency.md)). |
| `fromPubSub` | Each run has its own buffer: unbounded by default, or `opts.buffer` with `opts.strategy`. The publisher never waits. |
| `async`, `event`, `Fx.net.stream`, `StateKey:changes` | Values wait in a buffer of `opts.buffer` (default 1024). When it is full, `strategy = 'sliding'` (default) drops the oldest value, `'dropping'` drops the newest. |
| `Fx.security.stream`, `Fx.trace.stream` | Buffer of `opts.buffer` (default 1024), always sliding. |
| `merge`, `groupedWithin`, `debounce` | The upstream runs on its own fiber and feeds an internal queue of 16 values. When that queue is full the upstream waits. Upstream can run up to about 16 values ahead of what the consumer has taken. |
| `interruptAfter` | Same, with an internal queue of 1. |

### Stopping

A stream stops when:

- its source ends by itself (`make` runs out, `finish()` is called in `async`);
- the consumer stops it (`take`, `takeWhile`, `takeUntil`, `runForEachWhile` returning `false`, `runHead`);
- it fails (a source fails, a callback's effect fails, a callback raises);
- the fiber running it is interrupted (`fiber:interrupt()`, a `:timeout`, the resource stopping, a player scope closing).

However it stops, everything it set up is undone before the run effect finishes: `async` cleanup functions run, so `event` removes its `AddEventHandler`, `Fx.net.stream` removes its net event handler and `StateKey:changes` removes its state bag change handler. `fromPubSub` unsubscribes, timers used by `groupedWithin`, `debounce` and `interruptAfter` are cancelled, the fibers behind `merge` are interrupted, and `ensuring` finalizers run.

```lua
-- The handler for 'rivo:ping' exists only while this runs: take(3) stops the
-- stream after the third value and RemoveEventHandler is called.
Fx.runFork(Fx.Stream.event('rivo:ping'):take(3):runForEach(print))
```

## Sources

### Fx.Stream.make(...)

```lua
Fx.Stream.make(...: any): Fx.Stream<any>
```

- **Parameters:** `...`, the values, in order. `nil` arguments are kept.
- **Returns:** a stream that emits the values, then ends.
- **Fails with:** never.
- **Notes:** both sides. Values are produced on demand (pull).

```lua
local Loadout = Fx.Stream.make('WEAPON_PISTOL', 'WEAPON_BAT', 'WEAPON_FLASHLIGHT')

Fx.runFork(Loadout:runForEach(function(name)
  GiveWeaponToPed(PlayerPedId(), joaat(name), 50, false, false)
end))
```

### Fx.Stream.fromTable(list)

```lua
Fx.Stream.fromTable(list: any[]): Fx.Stream<any>
```

- **Parameters:** `list`, an array.
- **Returns:** a stream of `list[1]`, `list[2]`, ... up to `#list`.
- **Fails with:** never.
- **Notes:** both sides. The list is read while the stream runs, not when `fromTable` is called, so changes made before the run are seen. Iteration stops at `#list`, so a hole may end it early.

```lua
-- server: pay every online player, one at a time
Fx.runFork(Fx.Stream.fromTable(GetPlayers())
  :map(tonumber)
  :mapEffect(function(src) return Bank.deposit(src, 250) end)
  :runDrain())
```

### Fx.Stream.range(from, to)

```lua
Fx.Stream.range(from: integer, to?: integer): Fx.Stream<integer>
```

- **Parameters:** `from`, the first value; `to`, the last value, inclusive (default `math.huge`, so forever).
- **Returns:** `from, from + 1, ..., to`.
- **Fails with:** never.
- **Notes:** both sides. Without `to`, cut it with `take` or `takeWhile`.

```lua
-- spawn slots 1..8 in order
Fx.runFork(Fx.Stream.range(1, 8)
  :mapEffect(function(slot) return Garage.spawnInSlot(slot) end)
  :runDrain())
```

### Fx.Stream.iterate(seed, f)

```lua
Fx.Stream.iterate(seed: any, f: fun(v: any): any): Fx.Stream<any>
```

- **Parameters:** `seed`, the first value; `f`, computes the next value from the previous one.
- **Returns:** `seed, f(seed), f(f(seed)), ...` forever.
- **Fails with:** never (a raising `f` is a defect).
- **Notes:** both sides. `f` runs only when the next value is needed.

```lua
-- wanted level escalation thresholds: 100, 200, 400, 800, 1600
local thresholds = Fx.Stream.iterate(100, function(x) return x * 2 end):take(5)
CreateThread(function()
  local list = Fx.runAwait(thresholds:runCollect())   -- { 100, 200, 400, 800, 1600 }
end)
```

### Fx.Stream.empty

```lua
Fx.Stream.empty: Fx.Stream<never>
```

- **Returns:** a stream that ends at once with no values. It is a value, not a function.
- **Fails with:** never.
- **Notes:** both sides. Useful as the fallback in `catchAll` or a branch in `flatMap`.

```lua
local events = Fx.net.stream('hud:ping', Fx.S.unknown)
  :catchAll(function() return Fx.Stream.empty end)
```

### Fx.Stream.never

```lua
Fx.Stream.never: Fx.Stream<never>
```

- **Returns:** a stream that never emits and never ends. It is a value, not a function.
- **Fails with:** never.
- **Notes:** both sides. Stops only when the consumer is interrupted or an operator like `interruptAfter` or `merge` ends it.

```lua
-- keep a merged stream open after the warm-up values
local warmup = Fx.Stream.make('ready'):concat(Fx.Stream.never)
```

### Fx.Stream.fail(err)

```lua
Fx.Stream.fail(err: any): Fx.Stream<never>
```

- **Parameters:** `err`, the error (usually a tagged error).
- **Returns:** a stream that fails with `err` as soon as it runs.
- **Fails with:** `err`.
- **Notes:** both sides. Recover with `catchAll`.

```lua
local Closed = Fx.TaggedError('ShopClosed')
local stock = Fx.Stream.make('water', 'bread')
  :concat(Fx.Stream.fail(Closed {}))
  :catchAll(function(e) return Fx.Stream.make('closed: ' .. e._tag) end)
```

### Fx.Stream.fromEffect(eff)

```lua
Fx.Stream.fromEffect(eff: Fx.Effect<A, E>): Fx.Stream<A>
```

- **Parameters:** `eff`, an effect.
- **Returns:** a stream of one value: the result of `eff`. `eff` runs when the stream runs.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides.

```lua
local balance = Fx.Stream.fromEffect(Fx.rpc.call('bank:balance', { account = 'main' }))
```

### Fx.Stream.repeatEffect(eff)

```lua
Fx.Stream.repeatEffect(eff: Fx.Effect<A, E>): Fx.Stream<A>
```

- **Parameters:** `eff`, an effect run again for every value.
- **Returns:** a stream of each result, forever.
- **Fails with:** the first failure of `eff`, which ends the stream.
- **Notes:** both sides. There is no pause between runs; put the wait in `eff` (`eff:delay(ms)`) or use `interval(ms):mapEffect(...)`.

```lua
-- client: sample the player's coords every 500 ms
local coords = Fx.Stream.repeatEffect(
  Fx.sync(function() return GetEntityCoords(PlayerPedId()) end):delay(500))
```

### Fx.Stream.interval(ms)

```lua
Fx.Stream.interval(ms: integer): Fx.Stream<integer>
```

- **Parameters:** `ms`, the wait between values.
- **Returns:** `1, 2, 3, ...` forever. The first value comes after `ms`.
- **Fails with:** never.
- **Notes:** both sides. Uses `Fx.sleep`. The next wait starts after the consumer has handled the previous value, so the real period is `ms` plus the handling time.

```lua
-- server: save dirty inventories every 60 s
Fx.runFork(Fx.Stream.interval(60000)
  :mapEffect(function() return Inventory.flushDirty() end)
  :runDrain())
```

### Fx.Stream.fromSchedule(schedule)

```lua
Fx.Stream.fromSchedule(schedule: Fx.Schedule): Fx.Stream<integer>
```

- **Parameters:** `schedule`, a schedule ([Schedule](core-schedule.md)).
- **Returns:** `1, 2, 3, ...`. The first value is emitted at once; each later one after the schedule's next delay. Ends when the schedule stops.
- **Fails with:** never.
- **Notes:** both sides. A schedule that allows `n` recurrences gives `n + 1` values: `Fx.Schedule.spaced(50):take(2)` emits `1, 2, 3` over 100 ms. The delay is computed after the consumer has handled the value.

```lua
-- three reconnect attempts after the first, backing off
Fx.runFork(Fx.Stream.fromSchedule(Fx.Schedule.exponential(1000):take(3))
  :runForEachWhile(function(attempt)
    return Fx.sync(function() return not Radio.connect(attempt) end)
  end))
```

### Fx.Stream.fromQueue(q)

```lua
Fx.Stream.fromQueue(q: Fx.Queue): Fx.Stream<any>
```

- **Parameters:** `q`, a queue ([Concurrency](core-concurrency.md)).
- **Returns:** every value taken from `q`. Never ends by itself.
- **Fails with:** never.
- **Notes:** both sides. Values are taken, so two consumers of the same queue split its values between them. Values already in the queue when the stream starts are emitted.

```lua
local Jobs = Fx.Queue.unsafeMake(256, 'dropping')

-- producer: anywhere
Jobs:unsafeOffer({ plate = 'RIVO 001', action = 'impound' })

-- consumer: one job at a time
Fx.runFork(Fx.Stream.fromQueue(Jobs)
  :mapEffect(function(job) return Impound.handle(job) end)
  :runDrain())
```

### Fx.Stream.fromPubSub(ps, opts)

```lua
Fx.Stream.fromPubSub(ps: Fx.PubSub, opts?: { buffer?: integer, strategy?: 'sliding'|'dropping' }): Fx.Stream<any>
```

- **Parameters:** `ps`, a PubSub; `opts.buffer`, how many messages may wait for a slow consumer (default unbounded); `opts.strategy`, what to drop when the buffer is full: `'sliding'` (default, the oldest) or `'dropping'` (the newest).
- **Returns:** every message published after the stream starts. Never ends by itself.
- **Fails with:** never.
- **Notes:** both sides. Subscribes when the run starts and unsubscribes when it stops. Unlike `ps:subscribe()`, the subscription is not added to the consumer's Scope, so the consumer's own finalizers are not run when the stream ends. Set `buffer` for any PubSub fed by players: the default has no limit.

```lua
local Announcements = Fx.PubSub.unsafeMake()

Fx.runFork(Fx.Stream.fromPubSub(Announcements, { buffer = 50 })
  :runForEach(function(msg) TriggerClientEvent('chat:addMessage', -1, { args = { 'Server', msg } }) end))

Announcements:unsafePublish('Restart in 10 minutes')
```

### Fx.Stream.async(register, opts)

```lua
Fx.Stream.async(
  register: fun(push: fun(v: any), finish: fun(err?: any)): (fun()|nil),
  opts?: { buffer?: integer, strategy?: 'sliding'|'dropping' }
): Fx.Stream<any>
```

- **Parameters:**
  - `register(push, finish)`, called when the stream starts. `push(v)` adds a value and is safe to call from any callback (event handler, export, `SetTimeout`). `finish()` ends the stream after the buffered values; `finish(err)` fails it with `err` after the buffered values. `register` may return a cleanup function.
  - `opts.buffer`, values that may wait for a slow consumer (default 1024).
  - `opts.strategy`, when the buffer is full: `'sliding'` (default) drops the oldest value, `'dropping'` drops the newest.
- **Returns:** a stream of the pushed values.
- **Fails with:** `err` passed to `finish(err)`.
- **Notes:** both sides. The cleanup function runs however the stream stops: finished, stopped by the consumer, failed or interrupted. `push` and `finish` after the stream has stopped, or after `finish`, are ignored. Values pushed inside `register`, before the consumer waits, are buffered. This is the building block for wrapping any callback API.

```lua
-- client: every time the player enters a vehicle, from a baseevents-style callback
local enteredVehicle = Fx.Stream.async(function(push)
  local h = AddEventHandler('baseevents:enteredVehicle', function(veh, seat, name)
    push({ vehicle = veh, seat = seat, model = name })
  end)
  return function() RemoveEventHandler(h) end
end, { buffer = 16 })
```

### Fx.Stream.event(name, shape, opts)

```lua
Fx.Stream.event(name: string, shape?: function, opts?: { buffer?: integer, strategy?: 'sliding'|'dropping' }): Fx.Stream<any>
```

- **Parameters:** `name`, a local event name; `shape(...)`, optional, builds the value from the event arguments; `opts.buffer` and `opts.strategy` as in `async`.
- **Returns:** a stream with one value per event: the first argument, or `shape(...)` when given.
- **Fails with:** never.
- **Notes:** both sides. Registers with `AddEventHandler` when the stream starts and calls `RemoveEventHandler` when it stops. `shape` runs inside the handler, so `source` is set there. This does no validation and no rate limiting: for net events sent by players use [`Fx.net.stream`](#fxnetstreamname-schema-opts).

```lua
-- server: who joined, with source read inside the handler
Fx.runFork(Fx.Stream.event('playerJoining', function() return tonumber(source) end)
  :runForEach(function(src) return Fx.logInfo('player joining', { src = src }) end))

-- client: game events, shaped into one table
local gameEvents = Fx.Stream.event('gameEventTriggered', function(name, args)
  return { name = name, args = args }
end)
```

### Fx.Stream.merge(...)

```lua
Fx.Stream.merge(...: Fx.Stream<any>): Fx.Stream<any>
stream:merge(...: Fx.Stream<any>): Fx.Stream<any>
```

- **Parameters:** `...`, the streams. As a method, `a:merge(b, c)` merges `a`, `b` and `c`.
- **Returns:** the values of all streams, in the order they arrive.
- **Fails with:** the first failure of any source.
- **Notes:** both sides. Each source runs on its own fiber and feeds an internal queue of 16 values; sources wait when it is full. Ends when every source has ended. The first failure fails the merged stream and interrupts the other sources. Stopping the merged stream (`take`, interruption) interrupts every source. `merge()` with no streams ends at once. A source that ends interrupted on its own fails the merged stream instead of hanging it.

```lua
-- server: one feed of things the admin panel shows
local feed = Fx.Stream.merge(
  Fx.security.stream():map(function(ev) return 'security: ' .. ev.kind end),
  Fx.Stream.event('playerJoining', function() return 'join: ' .. GetPlayerName(source) end),
  Fx.Stream.interval(60000):map(function() return 'heartbeat' end))
```

### Fx.Stream.fromRun(run)

```lua
---@alias Fx.Emit fun(v: any): Fx.Effect<boolean, any>
Fx.Stream.fromRun(run: fun(emit: Fx.Emit): Fx.Effect<boolean, any>): Fx.Stream<any>
```

- **Parameters:** `run(emit)`, returns the effect that produces the stream. For each value it runs `emit(v)`, an effect that succeeds with `false` when the consumer wants no more values. After `false`, `run` must not emit again.
- **Returns:** a stream built from `run`. `run` is called each time the stream runs.
- **Fails with:** whatever `run`'s effect fails with.
- **Notes:** both sides. `run`'s effect should succeed with `true` when the stream ended by itself and `false` when the consumer stopped it; `concat` and `grouped` rely on that. Every stream is a table `{ run = run }`, so `stream.run(emit)` works on any stream. Prefer `async` or the other sources; use this when none fit.

```lua
-- emit pages of rows until a page comes back empty
local function vehiclePages(size)
  return Fx.Stream.fromRun(function(emit)
    local function loop(offset)
      return Garage.page(offset, size):flatMap(function(rows)
        if #rows == 0 then return Fx.succeed(true) end           -- ended by itself
        return emit(rows):flatMap(function(more)
          if more == false then return Fx.succeed(false) end     -- consumer stopped
          return loop(offset + size)
        end)
      end)
    end
    return loop(0)
  end)
end
```

### Fx.Stream.isStream(v)

```lua
Fx.Stream.isStream(v: any): boolean
```

- **Parameters:** `v`, any value.
- **Returns:** `true` when `v` is a stream.
- **Fails with:** never.
- **Notes:** both sides.

```lua
local function toStream(v)
  if Fx.Stream.isStream(v) then return v end
  return Fx.Stream.make(v)
end
```

## FiveM sources

### Fx.net.stream(name, schema, opts)

```lua
Fx.net.stream(
  name: string,
  schema: Fx.Schema,
  opts?: { rateLimit?: string|false, buffer?: integer, strategy?: 'sliding'|'dropping' }
): Fx.Stream<{ source: integer, input: any }>   -- server
): Fx.Stream<any>                                -- client: the input
```

- **Parameters:** `name`, the net event; `schema`, required (pass `Fx.S.unknown` to accept anything on purpose); `opts.rateLimit`, server only, per player, `"10/s"` by default, `false` to turn it off ([format](net-rpc.md#fxratelimiterparsespec)); `opts.buffer` and `opts.strategy` as in `Fx.Stream.async`.
- **Returns:** on the server, a stream of `{ source = src, input = input }`; on the client, a stream of the input.
- **Fails with:** never. Rejected events are dropped, not failures.
- **Notes:** both sides. Raises at call time when `schema` is not a schema. The net event handler is registered when the stream starts and removed when it stops. Each event goes through the same checks as [`Fx.net.handle`](net-rpc.md#fxnethandlename-schema-handler-opts), in this order: on the server, events without a player `source` (a server-side `TriggerEvent`) are ignored, then the rate limit is checked (a rejected payload still uses a token), then the schema. Server rejections become `rate_limited` or `invalid_payload` [security events](net-rpc.md#fxsecurity); on the client a payload that fails the schema is logged as a warning. Each run has its own rate limiter. Unlike `Fx.net.handle`, there is no span per event and nothing is tied to the player's scope.

```lua
-- server: radio channel joins, validated and rate limited
Fx.runFork(Fx.net.stream('radio:join', Fx.S.struct { channel = Fx.S.int:between(1, 999) }, { rateLimit = '3/s' })
  :runForEach(function(m) return Radio.join(m.source, m.input.channel) end))
```

### StateKey:changes(opts)

```lua
StateKey:changes(opts?: {
  bag?: Fx.StateBag|string,
  buffer?: integer,
  strategy?: 'sliding'|'dropping',
}): Fx.Stream<{ bag: string, value: any, replicated: boolean, player?: integer, entity?: integer }>
```

- **Parameters:** `opts.bag`, only changes of this bag (a bag from `Fx.state.player/entity/global`, or a bag name); `opts.buffer` and `opts.strategy` as in `Fx.Stream.async`.
- **Returns:** a stream of change records for this key: `bag` (the bag name), `value` (validated), `replicated`, and `player` or `entity` when the bag belongs to one.
- **Fails with:** never.
- **Notes:** both sides. Uses `StateKey:onChange`: values that fail the key's schema never reach the stream; on the server, an invalid value written by a client is reported as an `invalid_state` security event. Clearing a key emits a change with `value = nil`. The state bag change handler is added when the stream starts and removed (`RemoveStateBagChangeHandler`) when it stops. See [FiveM modules](fivem-modules.md) for `Fx.state`.

```lua
-- client: react to job changes, but not to every flicker
local Job = Fx.state.key('job', Fx.S.struct { name = Fx.S.string, grade = Fx.S.int })

Fx.runFork(Job:changes({ bag = Fx.state.player() })
  :debounce(250)
  :runForEach(function(change) return Hud.setJob(change.value) end))
```

### Fx.security.stream(opts)

```lua
Fx.security.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.SecurityEvent>
```

- **Parameters:** `opts.buffer`, how many events may wait for a slow consumer (default 1024). Past that the oldest are dropped; the strategy is always sliding.
- **Returns:** the security events published in this resource after the stream starts.
- **Fails with:** never.
- **Notes:** both sides, but the library only reports events on the server. Never ends by itself. See [Fx.security](net-rpc.md#fxsecurity) for event kinds and fields. `Fx.trace.stream` works the same way for finished spans ([Observability](observability.md)).

```lua
-- post bad payloads to a webhook in batches: when 20 have piled up,
-- or 10 s after the first of a batch, whichever comes first
Fx.runFork(Fx.security.stream()
  :filter(function(ev) return ev.kind ~= 'rate_limited' end)
  :groupedWithin(20, 10000)
  :runForEach(function(batch) return Webhook.post(batch) end))
```

## Operators

Operators return a new stream and leave the original unchanged.

### stream:map(f)

```lua
stream:map(f: fun(v: A): B): Fx.Stream<B>
```

- **Parameters:** `f`, a plain function.
- **Returns:** a stream of `f(v)` for each value.
- **Fails with:** never (a raising `f` fails the stream with a defect, or with the tagged error passed to `error`).
- **Notes:** both sides. For effects use `mapEffect`.

```lua
local srcs = Fx.Stream.fromTable(GetPlayers()):map(tonumber)
```

### stream:mapEffect(f)

```lua
stream:mapEffect(f: fun(v: A): Fx.Effect<B, E>): Fx.Stream<B>
```

- **Parameters:** `f`, returns an effect for each value.
- **Returns:** a stream of each effect's result.
- **Fails with:** the first failure of an effect from `f`.
- **Notes:** both sides. One effect at a time, in order; there is no concurrency option.

```lua
-- server: each online player's balance, looked up one at a time
local balances = Fx.Stream.fromTable(GetPlayers())
  :map(tonumber)
  :mapEffect(function(src) return Bank.balance(src) end)
```

### stream:filter(pred)

```lua
stream:filter(pred: fun(v: A): boolean): Fx.Stream<A>
```

- **Parameters:** `pred`, keeps values for which it returns a truthy value.
- **Returns:** a stream of the kept values.
- **Fails with:** never.
- **Notes:** both sides.

```lua
local bad = Fx.security.stream():filter(function(ev) return ev.kind == 'invalid_payload' end)
```

### stream:filterMap(f)

```lua
stream:filterMap(f: fun(v: A): B|nil): Fx.Stream<B>
```

- **Parameters:** `f`, returns a new value, or `nil` to drop the value.
- **Returns:** a stream of the non-nil results.
- **Fails with:** never.
- **Notes:** both sides. `false` is kept; only `nil` drops.

```lua
-- only damage events, as { victim, attacker }
local damage = Fx.Stream.event('gameEventTriggered', function(name, args) return { name = name, args = args } end)
  :filterMap(function(e)
    if e.name ~= 'CEventNetworkEntityDamage' then return nil end
    return { victim = e.args[1], attacker = e.args[2] }
  end)
```

### stream:tap(f)

```lua
stream:tap(f: fun(v: A): Fx.Effect<any, E>|nil): Fx.Stream<A>
```

- **Parameters:** `f`, called for each value; may return an effect, which finishes before the value moves on.
- **Returns:** the same values, unchanged.
- **Fails with:** the failure of an effect returned by `f`.
- **Notes:** both sides. A non-effect return value is ignored.

```lua
local joins = Fx.net.stream('radio:join', Fx.S.struct { channel = Fx.S.int })
  :tap(function(m) return Fx.logDebug('radio join', { src = m.source, channel = m.input.channel }) end)
```

### stream:take(n)

```lua
stream:take(n: integer): Fx.Stream<A>
```

- **Parameters:** `n`, how many values.
- **Returns:** the first `n` values, then the stream ends.
- **Fails with:** never.
- **Notes:** both sides. The source is stopped after the `n`th value and asked for nothing more, so `range(1):take(3)` computes three values and an event stream removes its handler. `n <= 0` ends at once without starting the source.

```lua
-- server: wait for the next three pings from players, then stop listening
Fx.runFork(Fx.net.stream('ping', Fx.S.unknown):take(3):runCollect():tap(function(pings)
  return Fx.logInfo('got pings', { count = #pings })
end))
```

### stream:takeWhile(pred)

```lua
stream:takeWhile(pred: fun(v: A): boolean): Fx.Stream<A>
```

- **Parameters:** `pred`.
- **Returns:** values while `pred` holds. The first value that fails it is dropped and ends the stream.
- **Fails with:** never.
- **Notes:** both sides. Counts as ending by itself (so `concat` continues).

```lua
local countdown = Fx.Stream.iterate(10, function(n) return n - 1 end)
  :takeWhile(function(n) return n > 0 end)   -- 10 .. 1
```

### stream:takeUntil(pred)

```lua
stream:takeUntil(pred: fun(v: A): boolean): Fx.Stream<A>
```

- **Parameters:** `pred`.
- **Returns:** values up to and including the first one for which `pred` holds, then the stream ends.
- **Fails with:** never.
- **Notes:** both sides.

```lua
-- client: health updates until the player is dead (the 0 is included)
local health = Fx.Stream.interval(250)
  :map(function() return GetEntityHealth(PlayerPedId()) end)
  :takeUntil(function(hp) return hp <= 0 end)
```

### stream:drop(n)

```lua
stream:drop(n: integer): Fx.Stream<A>
```

- **Parameters:** `n`, how many values to skip.
- **Returns:** every value after the first `n`.
- **Fails with:** never.
- **Notes:** both sides.

```lua
-- skip the first tick of an interval
local ticks = Fx.Stream.interval(1000):drop(1)
```

### stream:dropWhile(pred)

```lua
stream:dropWhile(pred: fun(v: A): boolean): Fx.Stream<A>
```

- **Parameters:** `pred`.
- **Returns:** the values from the first one that fails `pred` on. After that, every value passes.
- **Fails with:** never.
- **Notes:** both sides.

```lua
-- ignore job changes until the player has a real job
local jobs = Job:changes():dropWhile(function(c) return c.value == nil or c.value.name == 'unemployed' end)
```

### stream:scan(init, f)

```lua
stream:scan(init: S, f: fun(acc: S, v: A): S): Fx.Stream<S>
```

- **Parameters:** `init`, the starting accumulator; `f(acc, v)`, the next accumulator.
- **Returns:** a stream of each running total. `init` itself is not emitted.
- **Fails with:** never.
- **Notes:** both sides. `make(1, 2, 3):scan(0, add)` emits `1, 3, 6`.

```lua
-- running total of fines written this session
local totals = Fx.net.stream('police:fine', Fx.S.struct { amount = Fx.S.int:between(1, 100000) })
  :scan(0, function(sum, m) return sum + m.input.amount end)
```

### stream:changes(eq)

```lua
stream:changes(eq?: fun(a: A, b: A): boolean): Fx.Stream<A>
```

- **Parameters:** `eq(previous, current)`, optional equality; default `==`.
- **Returns:** the values that differ from the one before. The first value is always emitted.
- **Fails with:** never.
- **Notes:** both sides. Compares with the last emitted value.

```lua
-- client: the zone name, only when it changes
local zone = Fx.Stream.interval(1000)
  :map(function()
    local c = GetEntityCoords(PlayerPedId())
    return GetNameOfZone(c.x, c.y, c.z)
  end)
  :changes()
```

### stream:grouped(n)

```lua
stream:grouped(n: integer): Fx.Stream<A[]>
```

- **Parameters:** `n`, the list size, at least 1.
- **Returns:** lists of `n` values. When the source ends by itself, the remaining values are emitted as a shorter last list.
- **Fails with:** never.
- **Notes:** both sides. Raises when called with `n < 1`. A partial list is not emitted when something downstream stops the stream; an upstream `take` counts as ending, so `range(1):take(5):grouped(2)` gives `{1, 2}, {3, 4}, {5}`.

```lua
-- insert rows 100 at a time
Fx.runFork(Fx.Stream.fromTable(rows)
  :grouped(100)
  :mapEffect(function(chunk) return Logs.insertMany(chunk) end)
  :runDrain())
```

### stream:groupedWithin(n, ms)

```lua
stream:groupedWithin(n: integer, ms: integer): Fx.Stream<A[]>
```

- **Parameters:** `n`, the largest list, at least 1; `ms`, the longest a list waits after its first value arrived.
- **Returns:** lists of 1 to `n` values, emitted when full or `ms` after the first value of the list arrived, whichever is first. When the source ends, a partial list is emitted.
- **Fails with:** the source's failure.
- **Notes:** both sides. Raises when called with `n < 1`. Every value is emitted exactly once, in order, including a value that arrives in the same tick as the deadline. No empty lists are emitted. The source runs on its own fiber with an internal queue of 16. Good for batching writes and webhooks.

```lua
-- server: write kill feed rows in batches of 50 or every 5 s
Fx.runFork(Fx.net.stream('feed:kill', KillSchema)
  :groupedWithin(50, 5000)
  :runForEach(function(batch) return KillLog.insertMany(batch) end))
```

### stream:debounce(ms)

```lua
stream:debounce(ms: integer): Fx.Stream<A>
```

- **Parameters:** `ms`, the quiet period.
- **Returns:** a value only after `ms` pass with no newer value; the newest value wins. When the source ends, a pending value is still emitted.
- **Fails with:** the source's failure.
- **Notes:** both sides. Uses the platform clock. A value that arrives in the same tick as the deadline is not lost. The source runs on its own fiber with an internal queue of 16.

```lua
-- client: save settings 500 ms after the player stops moving the slider
Fx.runFork(Fx.Stream.event('settings:changed')
  :debounce(500)
  :runForEach(function(settings) return Fx.kvp.set('settings', settings) end))
```

### stream:throttle(ms)

```lua
stream:throttle(ms: integer): Fx.Stream<A>
```

- **Parameters:** `ms`, the window.
- **Returns:** at most one value per `ms`: a value is dropped when the last value let through was less than `ms` ago. The first value always passes.
- **Fails with:** never.
- **Notes:** both sides. Drops values; it never delays them. Uses the platform clock.

```lua
-- client: at most one "vehicle damaged" notification every 2 s
Fx.runFork(damage:throttle(2000):runForEach(function() Notify('Your vehicle took damage') end))
```

### stream:flatMap(f)

```lua
stream:flatMap(f: fun(v: A): Fx.Stream<B>): Fx.Stream<B>
```

- **Parameters:** `f`, returns a stream for each value.
- **Returns:** the values of each inner stream, one inner stream after another.
- **Fails with:** the first failure of the outer or an inner stream.
- **Notes:** both sides. Each inner stream runs to its end before the next outer value is taken. If the consumer stops, both the inner and the outer stream stop.

```lua
-- every player's vehicles, one player after another
local vehicles = Fx.Stream.fromTable(GetPlayers())
  :flatMap(function(src) return Fx.Stream.fromEffect(Garage.vehiclesOf(tonumber(src))) end)
  :flatMap(Fx.Stream.fromTable)
```

### stream:concat(that)

```lua
stream:concat(that: Fx.Stream<B>): Fx.Stream<A|B>
```

- **Parameters:** `that`, the stream to run next.
- **Returns:** this stream's values, then `that`'s.
- **Fails with:** the failure of either stream.
- **Notes:** both sides. `that` starts only when this stream ended by itself. When something downstream stops the stream first (a `take` after `concat` reaching its count), `that` never starts. A cut made upstream by `take`, `takeWhile` or `takeUntil` counts as ending, so `a:take(2):concat(b)` does run `b`.

```lua
local intro = Fx.Stream.make('Welcome to the server', 'Read the rules with /rules')
local tips = Fx.Stream.interval(300000):map(function() return Tips.random() end)
Fx.runFork(intro:concat(tips):runForEach(function(line) Notify(line) end))
```

### stream:catchAll(f)

```lua
stream:catchAll(f: fun(err: E): Fx.Stream<B>): Fx.Stream<A|B>
```

- **Parameters:** `f(err)`, returns the stream to continue with.
- **Returns:** this stream's values; if it fails with an expected error, the values of `f(err)` after it.
- **Fails with:** whatever `f(err)` fails with; defects and interruptions are not caught.
- **Notes:** both sides. Values already emitted stay emitted. Failures of the consumer (an effect from `runForEach` failing, a downstream callback raising) are not caught, only failures of the source side.

```lua
local NotFound = Fx.TaggedError('NotFound')
local rows = Fx.Stream.fromEffect(Fx.fail(NotFound {}))
  :catchAll(function(e) return Fx.Stream.make({ missing = e._tag }) end)
```

### stream:ensuring(fin)

```lua
stream:ensuring(fin: Fx.Effect<any, never>): Fx.Stream<A>
```

- **Parameters:** `fin`, an effect.
- **Returns:** the same values; `fin` runs when the stream stops.
- **Fails with:** never by itself.
- **Notes:** both sides. Runs on every kind of stop: ended, stopped by the consumer, failed, interrupted.

```lua
Fx.runFork(Fx.Stream.event('minigame:hit')
  :take(10)
  :ensuring(Fx.sync(function() TriggerEvent('minigame:over') end))
  :runDrain())
```

### stream:interruptAfter(ms)

```lua
stream:interruptAfter(ms: integer): Fx.Stream<A>
```

- **Parameters:** `ms`, how long the stream may run.
- **Returns:** the values that arrive within `ms`, then the stream ends normally (success).
- **Fails with:** the source's failure.
- **Notes:** both sides. The source is stopped at the deadline. A value the consumer is already handling is finished first; values waiting in the internal queue (one at most) are dropped. The source runs on its own fiber.

```lua
-- server: collect votes for 30 s
CreateThread(function()
  local votes = Fx.runAwait(Fx.net.stream('vote:cast', Fx.S.struct { map = Fx.S.string:maxLen(32) }, { rateLimit = '1/s' })
    :interruptAfter(30000)
    :runCollect())
  Votes.tally(votes)
end)
```

## Running

Each runner returns an effect. Run it with `Fx.runFork`, `Fx.yield` inside `Fx.gen`, or `Fx.runAwait` from a Citizen thread ([Effects](core-effects.md)).

### stream:runForEach(f)

```lua
stream:runForEach(f: fun(v: A): Fx.Effect<any, E>|any): Fx.Effect<nil, E>
```

- **Parameters:** `f`, called for each value; may return an effect, which finishes before the next value.
- **Returns:** an effect that succeeds with `nil` when the stream ends.
- **Fails with:** the stream's failure or the failure of an effect from `f`.
- **Notes:** both sides. Returning `false` does not stop the stream; use `runForEachWhile` for that.

```lua
Fx.runFork(Fx.net.stream('shop:buy', BuySchema)
  :runForEach(function(m) return Shop.buy(m.source, m.input) end))
```

### stream:runForEachWhile(f)

```lua
stream:runForEachWhile(f: fun(v: A): boolean|Fx.Effect<boolean, E>|nil): Fx.Effect<nil, E>
```

- **Parameters:** `f`, returns `false`, or an effect of `false`, to stop.
- **Returns:** an effect that succeeds with `nil` when the stream ends or `f` stops it.
- **Fails with:** the stream's failure or the failure of an effect from `f`.
- **Notes:** both sides. Any other return value (including `nil`) continues.

```lua
-- client: wait until the ped is on foot
CreateThread(function()
  Fx.runAwait(Fx.Stream.interval(100):runForEachWhile(function()
    return IsPedInAnyVehicle(PlayerPedId(), false)
  end))
  Notify('You are on foot')
end)
```

### stream:runDrain()

```lua
stream:runDrain(): Fx.Effect<nil, E>
```

- **Returns:** an effect that runs the stream for its effects and ignores the values.
- **Fails with:** the stream's failure.
- **Notes:** both sides.

```lua
Fx.runFork(Fx.Stream.interval(60000):mapEffect(function() return Inventory.flushDirty() end):runDrain())
```

### stream:runCollect()

```lua
stream:runCollect(): Fx.Effect<A[], E>
```

- **Returns:** an effect that succeeds with every value in a list, once the stream ends.
- **Fails with:** the stream's failure.
- **Notes:** both sides. Never ends on an infinite stream; bound it with `take` or `interruptAfter`. A `nil` value leaves a hole in the list, which makes `#list` unreliable.

```lua
Fx.runFork(Fx.gen(function()
  local top = Fx.yield(Fx.Stream.fromTable(scores)
    :filter(function(s) return s.points > 100 end)
    :take(10)
    :runCollect())
  TriggerClientEvent('scoreboard:top', -1, top)
end))
```

### stream:runFold(init, f)

```lua
stream:runFold(init: S, f: fun(acc: S, v: A): S): Fx.Effect<S, E>
```

- **Parameters:** `init`, the starting accumulator; `f(acc, v)`, the next accumulator.
- **Returns:** an effect that succeeds with the final accumulator.
- **Fails with:** the stream's failure.
- **Notes:** both sides.

```lua
local totalCash = Fx.Stream.fromTable(accounts)
  :runFold(0, function(sum, acc) return sum + acc.cash end)   -- an effect of the sum
```

### stream:runCount()

```lua
stream:runCount(): Fx.Effect<integer, E>
```

- **Returns:** an effect that succeeds with the number of values, `nil` values included.
- **Fails with:** the stream's failure.
- **Notes:** both sides.

```lua
-- client: how many targets were hit in 10 s
local hits = Fx.Stream.event('range:hit'):interruptAfter(10000):runCount()
```

### stream:runHead()

```lua
stream:runHead(): Fx.Effect<A|nil, E>
```

- **Returns:** an effect that succeeds with the first value, or `nil` when the stream is empty. The stream is stopped after the first value.
- **Fails with:** the stream's failure.
- **Notes:** both sides. A first value of `nil` and an empty stream both give `nil`.

```lua
-- server: wait for the next player to send 'ready'
Fx.runFork(Fx.gen(function()
  local first = Fx.yield(Fx.net.stream('lobby:ready', Fx.S.unknown):runHead())
  print('first ready player', first.source)
end))
```

### stream:runLast()

```lua
stream:runLast(): Fx.Effect<A|nil, E>
```

- **Returns:** an effect that succeeds with the last value, or `nil` when the stream is empty.
- **Fails with:** the stream's failure.
- **Notes:** both sides. Never ends on an infinite stream.

```lua
-- the record of the third lap, once it arrives
local finalLap = Fx.Stream.event('race:lap'):takeUntil(function(lap) return lap.n == 3 end):runLast()
```

### stream:runFork(f)

```lua
stream:runFork(f?: fun(v: A): Fx.Effect<any, E>|any): Fx.Effect<Fx.Fiber, never>
```

- **Parameters:** `f`, optional, as in `runForEach`.
- **Returns:** an effect that starts `runForEach(f)` on a new child fiber and succeeds with the fiber at once.
- **Fails with:** never (the fiber carries the stream's outcome).
- **Notes:** both sides. This is `stream:runForEach(f):fork()`: the fiber is a child of the fiber that ran this effect and is interrupted when that fiber finishes. To run a stream for the life of the resource, use `Fx.runFork(stream:runForEach(f))` instead ([Concurrency](core-concurrency.md)).

```lua
Fx.runFork(Fx.gen(function()
  -- the heartbeat runs while this fiber waits for the round to end
  local beat = Fx.yield(Fx.Stream.interval(5000):runFork(function() TriggerClientEvent('round:beat', -1) end))
  Fx.yield(Round.waitForEnd())
  Fx.yield(beat:interrupt())
end))
```
