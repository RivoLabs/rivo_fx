# Net events and RPC

`Fx.net` registers net events that validate their payload against a schema and rate limit each player before your handler runs. `Fx.rpc` adds request/response calls over net events, with timeouts, cancellation and tagged errors that arrive on the caller as the same tag. `Fx.security` reports what the server rejected, `Fx.RateLimiter` is the token bucket behind the rate limits, and `Fx.compat` bridges ox_lib callbacks while you migrate. Use these for anything a player can send: never trust a client payload without a schema.

Schemas are covered in [Schema](core-schema.md), effects and tagged errors in [Effects](core-effects.md) and [Errors](core-errors.md). The wire format is specified in [docs/PROTOCOL.md](../PROTOCOL.md); a summary is at the [end of this page](#wire-protocol-summary).

## Fx.net

### Fx.net.handle(name, schema, handler, opts)

```lua
Fx.net.handle(
  name: string,
  schema: Fx.Schema,
  handler: fun(src: integer, input: any): Fx.Effect<any, any>|nil,  -- server
         | fun(input: any): Fx.Effect<any, any>|nil,                -- client
  opts?: {
    rateLimit?: string|false,   -- server only, default '10/s'
    runtime?: Fx.Runtime,       -- default: the one set with Fx.setRuntime
    playerScoped?: boolean,     -- server only, default true
  }
): fun()   -- removes the handler
```

- **Parameters:**
  - `name`, the net event name.
  - `schema`, required. The payload is validated (and transformed) with it before the handler runs. Pass `Fx.S.unknown` to accept anything on purpose.
  - `handler`, on the server `handler(src, input)`, on the client `handler(input)`. It may return an effect, which runs on its own fiber, or nothing.
  - `opts.rateLimit`, server only: a [rate limit spec](#fxratelimiterparsespec) per player for this event, `"10/s"` by default, `false` to turn it off.
  - `opts.runtime`, the [Runtime](core-resources.md) whose services the handler's effect gets.
  - `opts.playerScoped`, server only: interrupt the handler's fiber when the player drops (default `true`).
- **Returns:** a function that removes the handler.
- **Fails with:** never; rejected events are dropped. Raises at call time when `name` is not a string, `schema` is not a schema, or `handler` is not a function.
- **Notes:** both sides. The event carries exactly one argument, the payload; other arguments are ignored. On the server each event is checked in this order:
  1. An event without a player `source` (a server-side `TriggerEvent`) is ignored.
  2. The rate limit. Over the limit: dropped, `rate_limited` security event.
  3. The schema. Invalid: dropped, `invalid_payload` security event with the schema's message.

  Then `rivo_fx_net_events_total{name}` is incremented and the handler runs. A rejected payload still uses a token. On the client there is no rate limit; a payload that fails the schema is logged as a warning, not reported. A handler that raises is logged as an error. A handler's effect runs in a span `net <name>` (kind `server`, attributes `net.event`, `player`), and its failures (not interruptions) are logged as errors. Each `Fx.net.handle` has its own rate limiter, separate from RPCs with the same name.

```lua
-- server
local Deposit = Fx.S.struct {
  amount = Fx.S.int:between(1, 1000000),
  note = Fx.S.string:maxLen(32):optional(),
}

Fx.net.handle('bank:deposit', Deposit, function(src, input)
  return Fx.gen(function()
    local bank = Fx.yield(Bank)
    local balance = Fx.yield(bank.deposit(src, input.amount))
    Fx.yield(Fx.net.emit('bank:balance', src, { balance = balance }))
  end)
end, { rateLimit = '5/s' })
```

```lua
-- client
Fx.net.handle('bank:balance', Fx.S.struct { balance = Fx.S.int }, function(input)
  SendNUIMessage({ type = 'balance', value = input.balance })
end)
```

### Fx.net.stream(name, schema, opts)

```lua
Fx.net.stream(name: string, schema: Fx.Schema, opts?: {
  rateLimit?: string|false, buffer?: integer, strategy?: 'sliding'|'dropping',
}): Fx.Stream<{ source: integer, input: any }>   -- server; the input on the client
```

- **Parameters:** as `Fx.net.handle`, plus `opts.buffer` (default 1024) and `opts.strategy` (`'sliding'` default, or `'dropping'`) for values waiting on a slow consumer.
- **Returns:** a stream of the events that pass the same checks as `Fx.net.handle`.
- **Fails with:** never.
- **Notes:** both sides. The handler is registered while the stream runs and removed when it stops. No span per event and no player scoping. Full reference in [Streams](streams.md#fxnetstreamname-schema-opts).

```lua
-- server
Fx.runFork(Fx.net.stream('radio:join', Fx.S.struct { channel = Fx.S.int:between(1, 999) })
  :runForEach(function(m) return Radio.join(m.source, m.input.channel) end))
```

### Fx.net.send(name, ...)

```lua
-- server
Fx.net.send(name: string, target: integer, payload: any)
-- client
Fx.net.send(name: string, payload: any)
```

- **Parameters:** `name`; `target` (server only), a player id or `-1` for everyone; `payload`, the one argument.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides, with different arguments. A plain call to `TriggerClientEvent(name, target, payload)` or `TriggerServerEvent(name, payload)`. The payload is not validated here; the receiver validates it.

```lua
-- server
Fx.net.send('hud:notify', src, { text = 'Paycheck received', kind = 'success' })
-- client
Fx.net.send('bank:deposit', { amount = 500 })
```

### Fx.net.broadcast(name, payload)

```lua
Fx.net.broadcast(name: string, payload: any)
```

- **Parameters:** `name`; `payload`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** server only (`nil` on the client). Same as `Fx.net.send(name, -1, payload)`.

```lua
Fx.net.broadcast('weather:set', { type = 'RAIN', transitionMs = 15000 })
```

### Fx.net.emit(name, ...)

```lua
-- server
Fx.net.emit(name: string, target: integer, payload: any): Fx.Effect<nil, never>
-- client
Fx.net.emit(name: string, payload: any): Fx.Effect<nil, never>
```

- **Parameters:** as `Fx.net.send`.
- **Returns:** an effect that sends the event when it runs.
- **Fails with:** never.
- **Notes:** both sides. Use it inside `Fx.gen` and pipelines.

```lua
Fx.yield(Fx.net.emit('bank:balance', src, { balance = balance }))
```

### Fx.net.isSchema(v)

```lua
Fx.net.isSchema(v: any): boolean
```

- **Parameters:** `v`.
- **Returns:** `true` when `v` is a schema built with `Fx.S`.
- **Fails with:** never.
- **Notes:** both sides. The check `handle`, `stream` and `Fx.rpc.register` use.

```lua
assert(Fx.net.isSchema(Deposit), 'Deposit must be a schema')
```

## Fx.rpc

An RPC has a host, which registers a handler, and a caller. Clients call server RPCs with `Fx.rpc.call`; the server calls client RPCs with `Fx.rpc.callClient`. Lua and JS ([JS](js.md)) resources speak the same protocol, so a Lua client can call a TypeScript server RPC.

### Fx.rpc.register(name, spec, handler)

```lua
Fx.rpc.register(
  name: string,
  spec: {
    input: Fx.Schema,            -- required
    output?: Fx.Schema,
    rateLimit?: string|false,    -- server only, default '10/s'
    runtime?: Fx.Runtime,
    libCallback?: boolean,       -- also register an ox_lib callback
  },
  handler: fun(src: integer, input: any): Fx.Effect<any, any>|any,   -- server
         | fun(input: any): Fx.Effect<any, any>|any                  -- client
): fun()   -- unregisters
```

- **Parameters:**
  - `name`, the RPC name (at most 128 characters on the wire).
  - `spec.input`, required; the input is validated (and transformed) before the handler runs. `Fx.S.unknown` accepts anything on purpose.
  - `spec.output`, optional; the handler's result is validated before replying.
  - `spec.rateLimit`, server only: per player, `"10/s"` by default, `false` to turn it off.
  - `spec.runtime`, the Runtime whose services the handler gets (default: `Fx.setRuntime`'s).
  - `spec.libCallback = true`, also expose the handler as an ox_lib callback ([Fx.compat](#fxcompat)).
  - `handler`, `handler(src, input)` on the server, `handler(input)` on the client. Returns an effect or a plain value.
- **Returns:** a function that removes the handler; later calls get `RpcNotFound`.
- **Fails with:** never at registration; raises when `name` is not a string or `spec.input` is not a schema. What the caller receives is listed under [error tags](#built-in-error-tags).
- **Notes:** both sides (client hosts are called with `callClient`). Registering the same name again replaces the handler. The handler's result is sent back as the value. If it fails with a tagged error, that error (its serialisable fields) is sent and rebuilt on the caller with the same `_tag`; raising a tagged error with `error(NotEnoughMoney { ... })` works the same. Defects, raised non-tagged errors and output that fails `spec.output` are logged on the host and reach the caller as `RpcInternalError` with no details. The handler runs on its own fiber in a span `rpc.server <name>` that continues the caller's trace ([Observability](observability.md#trace-propagation-over-fxrpc)), and its time is recorded in `rivo_fx_rpc_handler_ms{name,outcome}`. On the server the fiber is interrupted when the player drops. When the caller cancels or the fiber is interrupted, no response is sent. A second request with the same caller and id while the first still runs is ignored. Tagged error fields go to the client as they are: do not put secrets in them.

```lua
-- server
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

Fx.rpc.register('bank:withdraw', {
  input = Fx.S.struct { amount = Fx.S.int:between(1, 1e6) },
  output = Fx.S.int,
  rateLimit = '3/s',
}, function(src, input)
  return Fx.gen(function()
    local bank = Fx.yield(Bank)
    return Fx.yield(bank.withdraw(src, input.amount))   -- may fail with NotEnoughMoney
  end)
end)

Fx.rpc.register('bank:ping', { input = Fx.S.unknown }, function() return 'pong' end)
```

### Fx.rpc.call(name, input, opts)

```lua
Fx.rpc.call(name: string, input: any, opts?: {
  timeout?: integer,      -- ms, default 10000
  resource?: string,      -- the resource hosting the RPC, default this resource
  output?: Fx.Schema,     -- validate the reply on the caller
}): Fx.Effect<any, Fx.TaggedError>
```

- **Parameters:** `name`; `input`, sent as is (the host validates it); `opts.timeout`; `opts.resource`, to call an RPC registered in another resource; `opts.output`, a schema the reply must pass.
- **Returns:** an effect that sends the request when it runs and succeeds with the handler's value (transformed by `opts.output` when given).
- **Fails with:** `RpcTimeout`, `RpcNotFound`, `RpcInvalidInput`, `RpcRateLimited`, `RpcInternalError`, `RpcInvalidOutput`, or the tagged error the handler failed with (same `_tag` and fields).
- **Notes:** client only (`nil` on the server). Nothing is sent until the effect runs; each run sends a new request. If the calling fiber is interrupted, including by the timeout, a cancel is sent and the host interrupts the handler. The call runs in a span `rpc.client <name>` and its round trip is recorded in `rivo_fx_rpc_call_ms{name,outcome}`.

```lua
-- client
Fx.runFork(Fx.gen(function()
  local balance = Fx.yield(
    Fx.rpc.call('bank:withdraw', { amount = 500 }, { timeout = 5000 })
      :catchTag('NotEnoughMoney', function(e) return Fx.succeed(e.have) end)
      :catchTag('RpcTimeout', function() return Fx.succeed(nil) end))
  print('balance now', balance)
end))

-- an RPC hosted by another resource
local stock = Fx.rpc.call('shop:stock', { shop = 'ltd_grove' }, { resource = 'rivo_shops', output = Fx.S.array(Fx.S.string) })
```

### Fx.rpc.callClient(player, name, input, opts)

```lua
Fx.rpc.callClient(player: integer, name: string, input: any, opts?: {
  timeout?: integer, resource?: string, output?: Fx.Schema,
}): Fx.Effect<any, Fx.TaggedError>
```

- **Parameters:** `player`, the player's server id (converted with `tonumber`); the rest as `Fx.rpc.call`.
- **Returns:** an effect that sends the request to that player and succeeds with the client handler's value.
- **Fails with:** as `Fx.rpc.call`. A client can reply with any tag it likes, so treat tags from clients as untrusted.
- **Notes:** server only (`nil` on the client). Only a response from that player is accepted; responses from anyone else are ignored. The client host does not rate limit. Span `rpc.client <name>` gets a `player` attribute.

```lua
-- server
Fx.runFork(Fx.rpc.callClient(src, 'hud:getSettings', {}, { timeout = 2000 })
  :flatMap(function(settings) return Profiles.saveHud(src, settings) end)
  :catchTag('RpcTimeout', function() return Fx.logWarn('client did not answer', { src = src }) end))
```

```lua
-- client
Fx.rpc.register('hud:getSettings', { input = Fx.S.struct {} }, function()
  return { safeZone = GetSafeZoneSize(), minimap = not IsRadarHidden() }
end)
```

### Built-in error tags

Each is a tagged error class on `Fx.rpc` (`Fx.rpc.RpcTimeout.is(e)`), and each tag works with `catchTag`.

| Tag | Raised by | When | Fields |
|---|---|---|---|
| `RpcNotFound` | host | no handler with that name in the target resource | `name` |
| `RpcInvalidInput` | host | the input failed `spec.input` | `name`, `message` |
| `RpcRateLimited` | host (server) | the player exceeded `spec.rateLimit` | `name` |
| `RpcInternalError` | host, or caller | the handler died, raised a non-tagged error or returned output that failed `spec.output`; also a reply whose `error` is not a tagged table | `name` |
| `RpcTimeout` | caller | no reply within `opts.timeout` (default 10000 ms) | `name`, `timeoutMs` |
| `RpcInvalidOutput` | caller | the reply failed `opts.output` | `name`, `message` |

An interrupted handler (cancelled, player dropped) sends no reply, so the caller sees `RpcTimeout` unless it was the one that cancelled.

```lua
local function notify(text) return Fx.sync(function() Notify(text) end) end

Fx.runFork(Fx.rpc.call('garage:spawn', { plate = 'RIVO001' })
  :catchTags({
    RpcTimeout = function() return notify('Garage did not answer') end,
    RpcRateLimited = function() return notify('Slow down') end,
  }))
```

### RPC wire behaviour and cancellation

- Each resource that registers or calls RPCs listens on `__rfx:<res>:req`, `__rfx:<res>:res` and `__rfx:<res>:cancel`, where `<res>` is its resource name.
- A call sends `{ id, name, from, input, trace }` to `__rfx:<target>:req`, where `<target>` is `opts.resource` or the caller's own resource. The host replies to `__rfx:<from>:res` with `{ id, ok = true, value }` or `{ id, ok = false, error = { _tag, ... } }`.
- On the server, requests, cancels and responses without a player `source` are ignored.
- The host checks each request in order and stops at the first problem: a malformed envelope is dropped with no reply (on the server, an `invalid_payload` security event named `__rfx:<res>:req`); an unknown name replies `RpcNotFound` (server: `unknown_rpc`, not rate limited); the rate limit replies `RpcRateLimited` (`rate_limited`); invalid input replies `RpcInvalidInput` (`invalid_payload`).
- Cancellation: when the calling fiber is interrupted (by the timeout too), the caller sends `{ id, from }` to `__rfx:<target>:cancel`. The host interrupts the handler for that caller and id if it is still running and sends nothing back.

## Fx.security

Security events describe client input the server rejected. They are published inside the resource that rejected it, counted in `rivo_fx_security_events_total{kind}`, logged (unless quiet), and fired as the local event `rivo_fx:security` so one anticheat resource can watch every resource.

| Field | Type | Meaning |
|---|---|---|
| `kind` | string | see below |
| `source` | integer? | the player id (for `invalid_state` on an entity, the entity owner; may be `nil`) |
| `name` | string | the net event, RPC or state key name |
| `message` | string? | the schema's message, for `invalid_payload` and `invalid_state` |
| `resource` | string | the resource that rejected it |
| `bag` | string? | the state bag name, for `invalid_state` |

| Kind | Reported when (server) |
|---|---|
| `invalid_payload` | a net event (`Fx.net.handle`, `Fx.net.stream`) or RPC input failed its schema; a malformed RPC envelope (name `__rfx:<res>:req`); an ox_lib callback registered with `libCallback` got invalid input |
| `rate_limited` | a player exceeded a net event, RPC or `libCallback` rate limit. Logged at debug level, the others at warn |
| `unknown_rpc` | a player called an RPC name that is not registered |
| `invalid_state` | a client wrote a value that fails a `Fx.state.key` schema to its own player or entity bag ([FiveM modules](fivem-modules.md)) |

### Fx.security.on(fn)

```lua
Fx.security.on(fn: fun(ev: Fx.SecurityEvent)): fun()
```

- **Parameters:** `fn`, called with each security event in this resource.
- **Returns:** a function that removes the listener.
- **Fails with:** never. An error raised by `fn` is reported as a defect.
- **Notes:** both sides; the library only reports on the server. Called synchronously when the event is reported.

```lua
Fx.security.on(function(ev)
  if ev.kind == 'invalid_payload' then
    Strikes[ev.source] = (Strikes[ev.source] or 0) + 1
    if Strikes[ev.source] >= 5 then DropPlayer(tostring(ev.source), 'Invalid network data') end
  end
end)
```

### Fx.security.stream(opts)

```lua
Fx.security.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.SecurityEvent>
```

- **Parameters:** `opts.buffer`, events that may wait for a slow consumer (default 1024; past that the oldest are dropped).
- **Returns:** a stream of security events reported after it starts.
- **Fails with:** never.
- **Notes:** both sides. See [Streams](streams.md#fxsecuritystreamopts).

```lua
Fx.runFork(Fx.security.stream()
  :filter(function(ev) return ev.kind ~= 'rate_limited' end)
  :groupedWithin(20, 10000)
  :runForEach(function(batch) return Webhook.post(batch) end))
```

### Fx.security.subscribe()

```lua
Fx.security.subscribe(): Fx.Effect<Fx.Queue, never>   -- requires Scope
```

- **Returns:** an effect that subscribes a queue to security events until the enclosing Scope closes.
- **Fails with:** never.
- **Notes:** both sides. The queue is unbounded. Prefer `Fx.security.stream()`, which bounds its buffer. See [Resources](core-resources.md) for scopes.

```lua
Fx.runFork(Fx.scoped(Fx.gen(function()
  local q = Fx.yield(Fx.security.subscribe())
  while true do
    local ev = Fx.yield(q:take())
    print('security', ev.kind, ev.source)
  end
end)))
```

### Fx.security.setQuiet(quiet)

```lua
Fx.security.setQuiet(quiet: boolean)
```

- **Parameters:** `quiet`, `true` to stop logging each event.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides, per resource. Events are still counted, published and fired as `rivo_fx:security`.

```lua
-- this resource sends its own summaries; skip the per-event log lines
Fx.security.setQuiet(true)
```

### Fx.security.report(ev)

```lua
Fx.security.report(ev: { kind: string, source?: integer, name: string, message?: string })
```

- **Parameters:** `ev`, a security event. You may use your own `kind`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Sets `ev.resource`, increments `rivo_fx_security_events_total{kind}`, logs it (debug for `rate_limited`, warn otherwise, unless quiet), publishes it to `on`, `stream` and `subscribe`, and calls `TriggerEvent('rivo_fx:security', ev, resourceName)`. The library calls it for its own checks; call it for yours.

```lua
Fx.net.handle('shop:buy', Buy, function(src, input)
  if #(GetEntityCoords(GetPlayerPed(src)) - Shops[input.shop].coords) > 10.0 then
    Fx.security.report({ kind = 'too_far', source = src, name = 'shop:buy', message = 'not at the shop' })
    return
  end
  return Shop.buy(src, input)
end)
```

### The rivo_fx:security event

```lua
AddEventHandler('rivo_fx:security', function(ev: Fx.SecurityEvent, resourceName: string) end)
```

- **Parameters:** `ev`, the event; `resourceName`, the resource that reported it.
- **Notes:** a local event (`TriggerEvent`) on the side that reported it, so any resource on that side can listen without depending on Rivo FX. Every resource that uses Rivo FX fires it.

```lua
-- in your anticheat resource (server)
AddEventHandler('rivo_fx:security', function(ev, resourceName)
  if ev.kind == 'invalid_payload' or ev.kind == 'unknown_rpc' then
    Anticheat.flag(ev.source, ('%s: %s on %s'):format(resourceName, ev.kind, ev.name))
  end
end)
```

## Fx.RateLimiter

Token buckets keyed by anything, usually the player id. A spec is `"<n>/s"`, `"<n>/m"` or `"<n>/h"`: capacity `n`, refilled continuously at `n` per period. Each `Fx.net.handle`, `Fx.net.stream` run and `Fx.rpc.register` has its own limiter, so the effective bucket is one per player per event or RPC.

### Fx.RateLimiter.new(spec)

```lua
Fx.RateLimiter.new(spec: string): Fx.RateLimiter
```

- **Parameters:** `spec`, for example `"10/s"`, `"30/m"`, `"100/h"`.
- **Returns:** a limiter with `take` and `forget`.
- **Fails with:** never; raises on an invalid spec.
- **Notes:** both sides. On the server, every limiter made with `new` forgets a player's bucket when the player drops.

```lua
local Robbery = Fx.RateLimiter.new('1/m')

Fx.net.handle('heist:start', Fx.S.struct { bank = Fx.S.string }, function(src, input)
  if not Robbery:take(src) then
    return Fx.net.emit('hud:notify', src, { text = 'Wait a minute before trying again' })
  end
  return Heist.start(src, input.bank)
end)
```

### Fx.RateLimiter.parse(spec)

```lua
Fx.RateLimiter.parse(spec: string): (capacity: integer, periodMs: integer)
```

- **Parameters:** `spec`, `"<n>/s"`, `"<n>/m"` or `"<n>/h"`. Spaces around the parts are allowed.
- **Returns:** the capacity `n` and the period in ms (1000, 60000 or 3600000).
- **Fails with:** never; raises `invalid rate limit "<spec>" (use "10/s", "30/m" or "100/h")` for any other format, and `rate limit must allow at least 1` for `n < 1`.
- **Notes:** both sides. The format every `rateLimit` option takes.

```lua
local n, period = Fx.RateLimiter.parse('30/m')   -- 30, 60000
```

### limiter:take(key)

```lua
limiter:take(key: any): boolean
```

- **Parameters:** `key`, usually a player id.
- **Returns:** `true` and uses one token when one is available; `false` when the bucket is empty.
- **Fails with:** never.
- **Notes:** both sides. A new key starts with a full bucket. Uses the platform clock.

```lua
local Horn = Fx.RateLimiter.new('3/s')
if Horn:take(src) then TriggerClientEvent('horn:play', -1, src) end
```

### limiter:forget(key)

```lua
limiter:forget(key: any)
```

- **Parameters:** `key`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Drops the bucket, so the key starts full again. Player buckets are forgotten on `playerDropped` automatically.

```lua
-- reset the cooldown after an admin revive
Robbery:forget(src)
```

## Fx.compat

Interop with ox_lib callbacks, for moving a codebase over step by step. Needs `@ox_lib/init.lua` loaded in the same resource.

### spec.libCallback (Fx.rpc.register)

```lua
Fx.rpc.register(name, { input = schema, libCallback = true, ... }, handler)
```

- **Parameters:** `libCallback = true` in an `Fx.rpc.register` spec.
- **Returns:** as `Fx.rpc.register`.
- **Fails with:** never; raises at registration when ox_lib is not loaded (the Fx RPC is already registered by then).
- **Notes:** both sides. Also registers `name` with `lib.callback.register`, so existing `lib.callback` / `lib.callback.await` callers keep working. The callback's first argument (after the player on the server) is the input. It shares the RPC's rate limiter and checks the input with `spec.input` (server: `rate_limited` / `invalid_payload` security events) and the output with `spec.output`. On a rejected input, an invalid output or a failure, the callback returns `nil` and failures are logged; tagged errors do not reach ox_lib callers. The ox_lib callback waits for the handler's effect to finish. The function returned by `Fx.rpc.register` does not remove the ox_lib callback.

```lua
-- server: new Fx callers and old lib.callback callers share one handler
Fx.rpc.register('garage:list', { input = Fx.S.struct { garage = Fx.S.string }, libCallback = true },
  function(src, input) return Garage.list(src, input.garage) end)

-- old client code keeps working:
-- local vehicles = lib.callback.await('garage:list', false, { garage = 'pillbox' })
```

### Fx.compat.libCallback(name, ...)

```lua
Fx.compat.libCallback(name: string, ...: any): Fx.Effect<any, Fx.TaggedError>
-- server: Fx.compat.libCallback(name, playerId, ...args, opts?)
-- client: Fx.compat.libCallback(name, ...args, opts?)
```

- **Parameters:** `name`, the ox_lib callback; on the server the first argument after `name` is the player id; then the callback's arguments. An optional last argument from `Fx.compat.opts { timeout = ms }` sets the timeout (default 10000).
- **Returns:** an effect that calls the ox_lib callback (client: a server callback; server: a client callback) and succeeds with its first return value.
- **Fails with:** `RpcTimeout` (`name`, `timeoutMs`) when no answer arrives in time. A missing ox_lib is a defect.
- **Notes:** both sides. The remote callback is not cancelled on timeout or interruption.

```lua
-- client: call an existing ox_lib server callback from Fx code
Fx.runFork(Fx.gen(function()
  local cash = Fx.yield(Fx.compat.libCallback('esx_bank:getCash', 'main', Fx.compat.opts { timeout = 5000 }))
  print('cash', cash)
end))

-- server: ask a client through its ox_lib callback
local coords = Fx.compat.libCallback('admin:getCoords', src)
```

### Fx.compat.opts(t)

```lua
Fx.compat.opts(t: { timeout?: integer }): table
```

- **Parameters:** `t`, the options.
- **Returns:** `t`, marked as options so `Fx.compat.libCallback` does not send it as an argument.
- **Fails with:** never.
- **Notes:** both sides.

```lua
Fx.compat.libCallback('police:getDuty', Fx.compat.opts { timeout = 2000 })
```

## Wire protocol summary

The full specification, shared by the Lua and JS implementations, is [docs/PROTOCOL.md](../PROTOCOL.md). In short:

- A net event from `Fx.net` is a plain FiveM net event with exactly one argument, the payload, decoded with the receiver's schema before the handler runs.
- RPC uses three events per resource: `__rfx:<res>:req` carries `{ id, name, from, input, trace? }`, `__rfx:<res>:res` carries `{ id, ok, value }` or `{ id, ok, error }`, and `__rfx:<res>:cancel` carries `{ id, from }`.
- Only tagged errors cross the wire, with their `_tag` and serialisable fields. Defects become `RpcInternalError` without details.
- `trace` is the caller's W3C traceparent (at most 64 characters); a bad one starts a new trace and never rejects the request.
- Rate limits are token buckets per player and per event or RPC name, written `"<n>/s"`, `"<n>/m"` or `"<n>/h"`, default `"10/s"`.
