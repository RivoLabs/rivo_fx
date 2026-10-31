# Errors and gotchas

This page lists every error tag the Rivo FX Lua library and the JS packages produce, with the
module it comes from, when it happens, its fields and how to handle it. It then explains the three
ways an effect can end badly (failures, defects and interruptions), and closes with common mistakes
and their fixes, each taken from what the code actually does.

## Error tags

All tags below are expected failures (the `E` channel), so `:catchTag(tag, fn)` in Lua and
`Effect.catchTag(tag, fn)` in TypeScript handle them. Fields are the keys on the error value. Tags
marked "wire only" are never raised as a Lua failure; they appear only in a response sent to a
caller or a page.

### Lua core

| Tag | Module | When | Fields | How to handle |
|---|---|---|---|---|
| `TimeoutError` | `Fx.TimeoutError` (`eff:timeout(ms)`) | the effect took longer than `ms`; it is interrupted | `timeoutMs` | `:catchTag('TimeoutError', ...)`, retry it, or use `:timeoutOption(ms)` (succeeds with `nil`) or `:timeoutFail(ms, fn)` (your own error) |
| `NoSuchElementError` | `Fx.NoSuchElementError` (`Fx.fromNullable(v)`) | `v` is `nil` and no `onNil` was given | none | pass `onNil` to fail with your own error |
| `UnknownError` | `Fx.UnknownError` (`Fx.try(fn)`) | `fn` raised something that is not a tagged error, and no `onError` was given | `message` (the `tostring` of what was raised), `cause` (the raised value) | pass `onError` to map it to your own tagged error |
| `ParseError` | `Fx.ParseError` (`schema:decode(v)`, `schema:parse(v)`) | `v` fails the schema. `decode` fails the effect; `parse` raises it | `message` (the schema message, for example `qty: must be between 1 and 10`) | catch it, or use `schema:validate(v)` to get `ok, valueOrMessage` without an error |
| `Interrupted` | `Fx.runAwait`, `Fx.runSync` | the effect was interrupted; this is what they raise. Not a declared class: a plain table | `_fxCause` (the cause) | `pcall(Fx.runAwait, eff)` and check `err._tag == 'Interrupted'` |

### Lua FiveM modules

| Tag | Module | When | Fields | How to handle |
|---|---|---|---|---|
| `RpcNotFound` | `Fx.rpc` | no handler with that name on the host. Also publishes `unknown_rpc` on a server host | `name` | check the name and the `resource` option; the host resource may not be started |
| `RpcInvalidInput` | `Fx.rpc` | the input failed the host's `spec.input`. Also publishes `invalid_payload` on a server host | `name`, `message` | fix the caller; show `message` to a developer, not a player |
| `RpcRateLimited` | `Fx.rpc` | the caller exceeded the handler's `rateLimit` (server hosts only). Also publishes `rate_limited` | `name` | back off; raise the limit if legitimate callers hit it |
| `RpcInternalError` | `Fx.rpc` | the handler died, failed with something that is not a tagged error, or returned a value that failed `spec.output`. The cause is logged on the host as `rpc "<name>" failed` | `name` | treat as a server bug; read the host's log or `/fxdev` Failures |
| `RpcTimeout` | `Fx.rpc` (caller), `Fx.compat.libCallback` | no response within `timeout` (default 10000 ms). The caller sends a cancel and the host interrupts its handler | `name`, `timeoutMs` | retry with a schedule, or tell the player the service did not answer |
| `RpcInvalidOutput` | `Fx.rpc` (caller) | the response failed the caller's `output` schema | `name`, `message` | the host and caller disagree on the shape; regenerate shared schemas |
| `ConfigError` | `Fx.config` | a convar is unset or `""` with no default, does not parse as the requested type, or a config file is missing, invalid JSON, fails to load, or fails its schema | `name` (convar name or file path), `message` | give a default, or let the resource fail to start with the message |
| `AssetNotFound` | `Fx.assets` | `model` (not in the CD image or not valid) or `animDict` (does not exist); the other loaders have no existence check | `kind`, `name` | check the asset name; do not retry |
| `AssetTimeout` | `Fx.assets` | the asset did not load in time (default 10000 ms) | `kind` (`model`, `animDict`, `animSet`, `ptfx`, `textureDict`, `scaleform`, `audioBank`), `name`, `timeoutMs` | retry once, or raise `timeout` for large assets |
| `EntityGone` | `Fx.entity` | `exists(ent)` or `requestControl(ent)` on an entity that does not exist | `entity` | the entity was deleted; stop working on it |
| `ControlTimeout` | `Fx.entity` (client) | `requestControl` did not get network control in time (default 5000 ms) | `entity`, `timeoutMs` | another client owns it; retry later |
| `NetIdTimeout` | `Fx.entity` | `fromNetId` did not find the entity in time (default 5000 ms) | `netId`, `timeoutMs` | the entity is out of scope or gone |
| `SpawnFailed` | `Fx.entity` | `spawnVehicle`/`spawnPed`/`spawnObject` created no entity in time. On the client the model load can also fail first with `AssetNotFound`/`AssetTimeout` | `kind` (`vehicle`, `ped`, `object`), `model` | check the model name; raise `timeout` if the server is slow to create it |
| `KvpInvalid` | `Fx.kvp` | `set`: the value fails its schema, cannot be JSON encoded, or would not come back the same (mixed array and string keys, holes, non-string keys) | `key`, `message` | fix the value shape |
| `KvpDecodeError` | `Fx.kvp` | `get`: the stored value is not valid JSON or fails the schema | `key`, `message` | delete or migrate the old value |
| `StateInvalid` | `Fx.state` | `key:get` found a value that fails the schema, or `key:set` was given one | `key`, `bag`, `message` | fix the writer; invalid client writes are also reported as `invalid_state` security events |
| `StateTimeout` | `Fx.state` | `key:await(bag, pred, { timeout })` timed out | `key`, `bag`, `timeoutMs` | the value never arrived; continue without it or retry |
| `SqlError` | `Fx.db` | the driver reported an error, or a transaction was rolled back (`message = 'transaction rolled back'`) | `method`, `sql` (absent for `transaction`), `message` | retry transient errors with `:retry(Fx.Schedule.exponential(100):take(3))`; log the rest |
| `SqlDecodeError` | `Fx.db` | a row (or the `scalar` value) failed `opts.row` (or `opts.value`) | `sql`, `index` (1-based row), `message` | the table and the schema disagree; fix one of them |
| `PlayerNotFound` | `Fx.framework` | the player has no character loaded (or, standalone, is not connected) | `source` | use `findPlayer` to get `nil` instead |
| `InsufficientFunds` | `Fx.framework` | `removeMoney` would go negative, or the framework refused the removal | `source`, `account`, `need`, `have` | show `need` and `have` to the player |
| `FrameworkError` | `Fx.framework` | unknown account (not `cash`/`bank`), invalid amount (negative, NaN, infinite), the framework raised, refused to add money, or the job/grade does not exist | `message` | a bug in the caller or a framework mismatch; log it |
| `NuiInvalidInput` | `Fx.nui.handle` (wire only) | the page's body failed `spec.input` | `name`, `message` | fix the page |
| `NuiInvalidMessage` | `Fx.nui.send` | the payload failed the schema given to `send` | `type`, `message` | fix the payload |
| `NuiInternalError` | `Fx.nui.handle` (wire only) | the handler died or failed without a tag, or its value failed `spec.output`. Logged as `nui callback "<name>" failed` | `name` | treat as a client script bug |
| `NuiInterrupted` | `Fx.nui.handle` (wire only) | the handler's fiber was interrupted (for example the resource is stopping), so the page's fetch still gets an answer | `name` | ignore, or close the page |

Your own tags come from `Fx.TaggedError('Name', fields?)`. With `fields` (a table of schemas), the
constructor raises `invalid fields for Name: <message>` when the props do not match.

### JS: @rivolabs/fx

| Tag | Module | When | Fields | How to handle |
|---|---|---|---|---|
| `RpcNotFound`, `RpcInvalidInput`, `RpcRateLimited`, `RpcInternalError`, `RpcTimeout`, `RpcInvalidOutput` | `Rpc` (both sides) | as in Lua, same tags and fields (`RpcRateLimited` only from a server host). A handler defect is logged as `RPC "<name>" died` | as in Lua | `Effect.catchTag`; they are real classes on the caller |
| any other tag | `Rpc.call`, `Rpc.callClient` | the host failed with a tagged error that `errors` did not decode | `_tag` plus the host's fields | `RemoteError`: `Effect.catchTag("YourTag", ...)`, read fields with `e["field"]`, or pass `errors` |
| `InvalidModel` | `Assets.model` | `IsModelInCdimage` or `IsModelValid` is false | `model` | check the model |
| `InvalidAnimDict` | `Assets.animDict` | `DoesAnimDictExist` is false | `animDict` | check the name |
| `AssetTimeout` | `Assets` | the asset did not load in time (default 10000 ms) | `kind` (`model`, `animDict`, `ptfxAsset`), `asset`, `timeoutMs` | note: the Lua `AssetTimeout` names the field `name`, not `asset` |
| `EntityNotFound` | `Entity.requestControl` | the handle does not exist | `entity` | stop working on it |
| `EntityTimeout` | `Entity` | control or the network id did not resolve in time (default 5000 ms) | `operation` (`requestControl`, `fromNetId`), `id`, `timeoutMs` | retry or give up |
| `ConfigError` | `Config.*` (Effect's `Config`) | the convar is unset or does not parse | Effect's `ConfigError` | `Config.withDefault`, `Config.option` |

See [JS and TypeScript](js.md#error-classes) for the class signatures.

### JS: @rivolabs/fx-nui (the page)

`fetchNui` rejects with a `NuiError` whose `_tag` is one of these, and whose `fields` holds
everything the resource sent. Test with `isNuiError(e, 'Tag')`.

| Tag | When | Fields |
|---|---|---|
| your tag (`OutOfStock`, `InsufficientFunds`, `RpcTimeout`, ...) | the Lua handler failed with a tagged error, including one forwarded from `Fx.rpc.call` | the error's fields |
| `NuiInvalidInput` | the body failed `spec.input` | `name`, `message` |
| `NuiInternalError` | a defect or untagged failure in the handler, or an `{ ok = false }` answer without a tagged error | `name` |
| `NuiInterrupted` | the handler's fiber was interrupted | `name` |
| `NuiTimeout` | no answer within `timeout` (default 10000 ms; `0` waits forever) | `name`, `timeoutMs` |
| `NuiTransportError` | the HTTP status was not OK, or the fetch failed or was aborted through `signal` | `name`, and `status` or `message` |

## Failures, defects and interruptions

An effect that does not succeed ends with a cause of one of three kinds:

- **Failure**: an expected error, the `E` in `Effect<A, E>`. Raised with `Fx.fail(e)`, `MyError { ... }:fail()`, or `error(MyError { ... })` inside `Fx.gen`/`Fx.sync`. `:catchAll`, `:catchTag`, `:catchTags`, `:mapError`, `:retry` and `:result` see failures only. Tagged failures cross RPC and NUI with their `_tag` and fields.
- **Defect**: a bug. Raised with `Fx.die(x)`, by any other `error(...)`, a nil index, a failed `spec.output`, or `:orDie()`. `:catchAll` does not catch it; `:catchAllDefect` and `:catchAllCause` do. A defect never crosses the wire: callers get `RpcInternalError { name }` and pages get `NuiInternalError { name }`, and the details are logged where it happened. A cause that holds both a failure and a defect counts as a defect.
- **Interruption**: the fiber was stopped from outside: a timeout, a cancelled RPC, a dropped player, a closed scope, a stopped resource, `fiber:interrupt()`. It is not an error. Finalizers (`:ensuring`, `:onInterrupt`, `Fx.acquireRelease`) still run, nothing catches it, an interrupted RPC handler sends no response, and fibers that end interrupted are not logged as unhandled failures.

`Fx.Cause.failures(c)`, `Fx.Cause.defects(c)`, `Fx.Cause.isInterruptedOnly(c)` and
`Fx.Cause.pretty(c)` take a cause apart. In TypeScript the same split is Effect's
`Cause` (`Cause.hasDies`, `Cause.hasInterruptsOnly`). See [Errors](core-errors.md).

## Common mistakes

### Calling Fx.yield outside Fx.gen

```lua
-- wrong: a plain function or thread
local hash = Fx.yield(Fx.assets.model('adder'))
-- raises: Fx.yield called outside Fx.gen. Wrap the code in Fx.gen(function() ... end), or use Fx.runAwait from a thread.

-- right, inside an effect
Fx.runFork(Fx.gen(function()
  local hash = Fx.yield(Fx.assets.model('adder'))
end))

-- right, from a Citizen thread
CreateThread(function()
  local hash = Fx.runAwait(Fx.assets.model('adder'))
end)
```

`Fx.yield(x)` where `x` is not an effect (often `nil`, from a function that forgot to `return`)
is a defect: `Fx.yield expects an effect, got nil`. A `:flatMap` function that returns a plain
value is a defect too: `expected an Fx effect but got number (5)`. Use `:map` for plain values.

### Forgetting a schema on Fx.net.handle or Fx.rpc.register

```lua
Fx.net.handle('shop:buy', function(src, input) end)
-- raises at registration: Fx.net.handle("shop:buy"): a schema is required (use Fx.S.unknown to skip validation on purpose)
Fx.rpc.register('shop:buy', {}, handler)
-- raises: Fx.rpc.register("shop:buy"): spec.input schema is required (use Fx.S.unknown to skip validation on purpose)
```

Pass a schema, or `Fx.S.unknown` to accept anything on purpose. `Fx.net.stream` raises the same
way, and `Fx.nui.handle` asserts `spec.input (a schema) is required`. In TypeScript the schema is a
required parameter, so it is a type error.

### Sending positional arguments instead of one table

A net event and an RPC carry exactly one payload. Extra arguments are dropped.

```lua
TriggerServerEvent('shop:buy', 'water', 2)
-- the server validates 'water' against the struct and reports:
-- [WARN] security: invalid_payload from player 3 on shop:buy message=expected object, got "water"

TriggerServerEvent('shop:buy', { item = 'water', qty = 2 })      -- right
Fx.net.send('shop:buy', { item = 'water', qty = 2 })            -- same, from a client
```

The same applies to `Fx.rpc.call(name, input, opts)`: the third argument is the options table, not
a second input. ox_lib callers moved with `libCallback = true` pass only their first argument as
the input.

### Using Wait instead of Fx.sleep in fibers

`Wait(ms)` and `Citizen.Await` inside `Fx.gen` work: the fiber borrows a Citizen thread for the
wait. But an interruption (a timeout, a dropped player, a stopped resource) cannot take effect
until the `Wait` returns, and `Fx.runSync` dies with
`Fx.runSync hit Citizen.Wait/Await inside Fx.gen. Use Fx.runFork or Fx.runAwait instead.`

```lua
Fx.gen(function()
  while true do
    Fx.yield(Fx.sleep(1000))   -- not Wait(1000): stays on the runner and stops at once when interrupted
    payWages()
  end
end)
```

For a fixed schedule use `eff:repeatWith(Fx.Schedule.spaced(1000))`. For per-frame work use
`Fx.tick.everyFrame`, `whileNear` or `whileTrue`, which run a plain thread that stops when the
fiber is interrupted.

### Expecting a defect's details on the client

```lua
Fx.rpc.register('bank:balance', { input = S.struct {} }, function(src)
  return Fx.sync(function() error('db pool exhausted') end)   -- a defect
end)
-- the client gets RpcInternalError { name = 'bank:balance' }; the server logs: rpc "bank:balance" failed
```

This is on purpose: a stack trace can leak server internals. If the client should know what went
wrong, fail with a tagged error: `return BankDown { retryInMs = 5000 }:fail()`. The same holds for
`Fx.nui.handle` (`NuiInternalError`) and the JS package (`RpcInternalError`, logged as
`RPC "<name>" died`). Also: a handler value that fails `spec.output` is a defect, so it becomes
`RpcInternalError`, not `RpcInvalidOutput` (that one is raised by the caller's own `output`).

### Label explosion in metrics

Every distinct label set is a series. Past 1000 series per metric, new label sets are dropped and
the resource logs once: `metric <name> has 1000 label sets; new ones are dropped`.

```lua
local Purchases = Fx.metrics.counter('shop_purchases_total')
Purchases:inc(1, { player = src })          -- wrong: one series per player id, forever
Purchases:inc(1, { item = input.item })     -- right: a small, fixed set of values
```

Use labels for small fixed sets (item, outcome, account) and put player ids in span attributes or
logs. The built-in RPC histograms label failures with the error tag only for tags declared in your
resource; a tag received from another side becomes `error`, so a client cannot make up label
values.

### The rivo_fx resource not started first

```
rivo_fx: cannot load lib/core/platform.lua (is rivo_fx started and up to date?)
```

`@rivo_fx/init.lua` reads the library from the `rivo_fx` resource at load time. Fix all of:

- the folder is named exactly `rivo_fx`;
- `server.cfg` has `ensure rivo_fx` before every resource that uses it;
- each resource's `fxmanifest.lua` has `dependency 'rivo_fx'`, `lua54 'yes'` and `shared_script '@rivo_fx/init.lua'` (before scripts that use `Fx`);
- after updating Rivo FX, restart `rivo_fx` and then the resources that use it.

JS resources using `@rivolabs/fx` do not need the `rivo_fx` resource.

### server.cfg ACE for /fxdev

Without permission, `/fxdev` prints
`/fxdev needs the rivo_fx.devtools permission (add_ace group.admin rivo_fx.devtools allow)` and
closes. The server checks the ACE on every request.

```cfg
add_ace group.admin rivo_fx.devtools allow
add_principal identifier.license:your_license_here group.admin
```

Spans and failures can hold player ids and error details, so grant it only to people who can read
the server console. JS resources do not appear in `/fxdev`.

### Clocks differing between client and server spans

Each side stamps spans with its own clock (Unix time anchored once, then a monotonic timer), and a
player's PC can be seconds away from the server. `/fxdev` compares times from each side with that
side's own "now", and in the waterfall a span that falls outside its parent from another clock is
moved inside the parent and marked `~`. Do not subtract a client timestamp from a server
timestamp. Measure round trips on one side: the `rpc.client` span's duration or the
`rivo_fx_rpc_call_ms` histogram (caller side), and handler time with `rivo_fx_rpc_handler_ms`
(host side).

### Calling an RPC in another resource without `resource`

Requests go to `__rfx:<target>:req`, and the target defaults to the caller's own resource.

```lua
Fx.rpc.call('garage:list', 'car')                                   -- goes to this resource
Fx.rpc.call('garage:list', 'car', { resource = 'garage', timeout = 5000 })   -- goes to 'garage'
```

Without it you get `RpcNotFound` (and an `unknown_rpc` security event against your own player) if
your resource hosts RPCs, or `RpcTimeout` if it does not.

### Handlers that need a service but no runtime

```
Service not found: rivo_fx/Framework. Provide it with :provide(layer) or :provideService(tag, impl).
```

A net or RPC handler that does `Fx.yield(Fx.framework.Framework)` (or any `Fx.Tag`) needs the
service provided. Call `Fx.setRuntime(Fx.Runtime.make(layer))` once, before the handlers run, or
pass `runtime = rt` in the handler options, or `:provide(layer)` on the effect. In TypeScript, use
`Layer.provideMerge(FxServer.layer)` so `runtime.runFork` can see the services; with
`Layer.provide` the compiler reports the missing service.

### Raising a plain error instead of a tagged one

Inside `Fx.gen` and `Fx.sync`, `error(NotFound { id = 1 })` is a failure, but `error('not found')`
is a defect: it skips `:catchAll`/`:catchTag` and reaches callers as `RpcInternalError`. Use
`NotFound { id = 1 }:fail()` (or `Fx.yield(NotFound { ... }:fail())` inside a gen) for anything
the caller should handle.

### Side-specific functions

`Fx.rpc.call` exists only on clients and `Fx.rpc.callClient` only on servers; calling the other
one is `attempt to call a nil value`. `Fx.net.send` takes `(name, target, payload)` on the server
and `(name, payload)` on the client. Server-side `Fx.net.handle` ignores events with no player
`source`, so a local `TriggerEvent(name, ...)` from another server script does not reach it.

### Running async effects with Fx.runSync

`Fx.runSync` runs right now and cannot wait. Anything that sleeps, waits for a callback or calls
the network dies with `Fx.runSync hit an async effect. Use Fx.runFork or Fx.runAwait instead.`
Use `Fx.runFork` (fire and forget, failures logged) or `Fx.runAwait` (block the current Citizen
thread and get the value).

### `while` and `until` in a retry policy

`eff:retry { times = 3, while = fn }` is a Lua syntax error (`unexpected symbol near 'while'`):
both are keywords. Write `['while'] = fn` / `['until'] = fn`, or use a schedule:
`eff:retry(Fx.Schedule.spaced(500):whileInput(fn):take(3))`.

### Empty convars

Lua `Fx.config` treats a convar set to `""` as unset (default or `ConfigError`). The JS
`Config.convarProvider` treats it as the value `""`. Use `setr`/`set` with a real value, or a
default on both sides.

### Forgetting the polyfill in a JS client

A client bundle without `import "@rivolabs/fx/polyfill"` as its first import fails at load with
`TextEncoder is not defined`. Importing `@rivolabs/fx/client` first is not enough: the built file
imports `effect` before its own copy of the polyfill runs. See [JS and TypeScript](js.md#why-the-polyfill-exists).
