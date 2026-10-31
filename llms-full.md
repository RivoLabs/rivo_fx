# Rivo FX reference

All Rivo FX documentation in one file, for reading start to finish or loading into an AI assistant. Generated from docs/reference by scripts/build-docs.mjs; edit those files, not this one.

Contents:

- [Introduction](#introduction)
- [Getting started](#getting-started)
- [Effects](#effects)
- [Errors and causes](#errors-and-causes)
- [Concurrency](#concurrency)
- [Scopes, services and Layers](#scopes-services-layers)
- [Schedule](#schedule)
- [Schema](#schema)
- [Streams](#streams)
- [Metrics, tracing and logs](#metrics-tracing-logs)
- [Devtools (/fxdev)](#devtools)
- [Net events and RPC](#net-events-and-rpc)
- [Players, config, assets, entities, ticks](#players-config-assets-entities)
- [KVP, state bags, database, frameworks](#kvp-state-database-frameworks)
- [NUI](#nui)
- [JavaScript and TypeScript (@rivolabs/fx)](#javascript-typescript)
- [CLI (rivo-fx)](#cli)
- [Recipes](#recipes)
- [Errors and gotchas](#errors-and-gotchas)
- [Moving a resource to Rivo FX](#migrating)

<a id="introduction"></a>

## Introduction
Rivo FX is a free, MIT-licensed library for FiveM resources, in Lua 5.4 and in JavaScript/TypeScript. It brings the model of [Effect](https://effect.website) to FiveM: errors are values you can see in the type, fibers clean up after themselves, services come from Layers, and every payload that crosses a trust boundary goes through a schema. On top of that it covers the FiveM parts scripts most often get wrong: net events, callbacks, asset loading, entities, state bags, NUI, the database and frameworks.

### What it fixes

- **Net events that validate first.** A handler never sees a payload that fails its schema, and every player is rate limited per event by default. Rejected payloads become security events you can log or send to a webhook.
- **RPC with timeouts and typed errors.** A `NotEnoughMoney` raised on the server arrives on the client as `NotEnoughMoney`, so `catchTag` works across the wire. Calls time out and cancel the handler. Defects never leak details to clients.
- **Cleanup that actually runs.** Scopes close when the resource stops or the player drops: spawned entities are deleted, models released and in-flight handlers interrupted.
- **No more `while not HasModelLoaded(m) do Wait(0) end`.** Asset loads have timeouts and typed errors.
- **One API over ESX, QBCore, Qbox and standalone**, typed oxmysql queries, schema-typed state bags and KVP.
- **Metrics, tracing and in-game devtools.** `/fxdev` shows live fibers, traces (a client call and its server handler share one trace), failures and metrics for every resource.

### Install

1. Download `rivo_fx.zip` from the [latest release](https://github.com/RivoLabs/rivo_fx/releases/latest), unzip it into your resources folder (the folder must be named `rivo_fx`) and `ensure rivo_fx` before anything that uses it.
2. In your resource's `fxmanifest.lua`:

```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

The library loads into your resource's own Lua runtime, the way `ox_lib` does. No exports sit on the hot path, and FiveM modules load on first use. The global `Fx` holds everything. See [Getting started](#getting-started) for types, convars and the JS packages.

### A taste

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

### Level 0: use it without learning Effect

Already have a codebase? Start with `Fx.runAwait`. It runs an effect from any Citizen thread and returns the value, or raises the error so `pcall` works:

```lua
CreateThread(function()
  local hash = Fx.runAwait(Fx.assets.model('adder', { timeout = 5000 }))
  -- ... spawn something
end)
```

### How these docs are organised

- **Core:** [Effects](#effects), [Errors](#errors-and-causes), [Concurrency](#concurrency), [Scopes, services and Layers](#scopes-services-layers), [Schedule](#schedule), [Schema](#schema).
- **Values over time and visibility:** [Streams](#streams), [Metrics, tracing and logs](#metrics-tracing-logs), [Devtools](#devtools).
- **FiveM:** [Net events and RPC](#net-events-and-rpc), [Players, config, assets, entities, ticks](#players-config-assets-entities), [KVP, state bags, database, frameworks](#kvp-state-database-frameworks), [NUI](#nui).
- **JavaScript and tools:** [JS/TS (@rivolabs/fx)](#javascript-typescript), [CLI (rivo-fx)](#cli).
- **Practical:** [Recipes](#recipes), [Errors and gotchas](#errors-and-gotchas), [Moving a resource to Rivo FX](#migrating).

Every reference page uses the same layout: one heading per function with its signature, parameters, return value, the errors it can fail with, notes and an example. The whole reference is also one file, [llms-full.md](https://github.com/RivoLabs/rivo_fx/blob/main/llms-full.md), for AI assistants.

### What's next

- OpenTelemetry (OTLP) export of spans and metrics
- A layer graph view in `/fxdev`
- An ox_core framework layer
- A TypeScript resource template for `rivo-fx create`

Source, issues and releases are on [GitHub](https://github.com/RivoLabs/rivo_fx). Security issues go through [private reporting](https://github.com/RivoLabs/rivo_fx/security/advisories/new).

<a id="getting-started"></a>

## Getting started
This page takes a resource from nothing to a validated net event and a typed RPC, and lists every setting Rivo FX reads: convars, ACE permissions and editor types. Read [Introduction](#introduction) first for what the library is.

### 1. Install the rivo_fx resource

Download `rivo_fx.zip` from the [latest release](https://github.com/RivoLabs/rivo_fx/releases/latest) and unzip it into your resources folder. The folder must be named `rivo_fx`. Start it before anything that uses it:

```cfg
ensure rivo_fx
ensure my_shop
```

### 2. Load it in your resource

```lua
-- my_shop/fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
server_script 'server.lua'
client_script 'client.lua'
```

`@rivo_fx/init.lua` defines the global `Fx` in your resource's runtime. Core modules load at once; FiveM modules (`Fx.net`, `Fx.rpc`, `Fx.assets`, ...) load the first time you use them. Lua 5.4 (`lua54 'yes'`) is required.

Or start from a template with the CLI ([CLI](#cli)):

```sh
npx @rivolabs/fx-cli create my_shop                      # server + client
npx @rivolabs/fx-cli create my_shop --template lua-nui   # plus a NUI page
```

### 3. A validated net event

```lua
-- server.lua
local S = Fx.S

Fx.net.handle('shop:buy', S.struct { item = S.string:maxChars(32), qty = S.int:between(1, 10) },
  function(src, input)
    return Fx.logInfo('purchase', { player = src, item = input.item, qty = input.qty })
  end)
```

```lua
-- client.lua
Fx.net.send('shop:buy', { item = 'water', qty = 2 })
```

The schema runs before the handler. A payload that fails it never reaches your code and is reported as a security event. Each player is limited to 10 calls per second per event unless you pass `{ rateLimit = '5/s' }` (or `false`). See [Net events and RPC](#net-events-and-rpc).

### 4. A typed RPC

```lua
-- server.lua
local OutOfStock = Fx.TaggedError('OutOfStock')
local stock = { water = 3 }

Fx.rpc.register('shop:stock', { input = S.string:maxChars(32) }, function(src, item)
  if (stock[item] or 0) == 0 then return OutOfStock { item = item }:fail() end
  return stock[item]
end)
```

```lua
-- client.lua
Fx.runFork(Fx.rpc.call('shop:stock', 'water', { timeout = 5000 })
  :map(function(n) print('in stock', n) end)
  :catchTag('OutOfStock', function(e) print('sold out:', e.item) return Fx.unit end))
```

### 5. Editor types

Point LuaLS at the bundled type definitions, for example in `.luarc.json`:

```json
{ "workspace.library": ["../rivo_fx/types"] }
```

### Settings Rivo FX reads

| Setting | Kind | Default | What it does |
|---|---|---|---|
| `rivo_fx:logLevel` | convar | `info` | `debug`, `info`, `warn`, `error` or `none` for `Fx.log` and the `Fx.logInfo` family |
| `rivo_fx:tracing` | convar | `on` | `off` stops recording spans |
| `rivo_fx:metricsToken` | convar (server, use `set`, not `setr`) | unset | turns on `/rivo_fx/metrics` and `/rivo_fx/spans`; requests need `Authorization: Bearer <token>` |
| `rivo_fx.devtools` | ACE | none | who may open `/fxdev`, e.g. `add_ace group.admin rivo_fx.devtools allow` |

See [Metrics, tracing and logs](#metrics-tracing-logs) and [Devtools](#devtools).

### JavaScript and TypeScript resources

```sh
npm install @rivolabs/fx effect       # resources, on the real Effect package
npm install @rivolabs/fx-nui          # NUI pages
```

JS and Lua resources speak the same protocol: a Lua client can call a TypeScript RPC and the other way round, and typed errors cross both ways. See [JS/TS](#javascript-typescript) and [NUI](#nui).

### Next

- New to effects: [Effects](#effects), then [Errors](#errors-and-causes).
- Moving an existing resource: [Moving a resource to Rivo FX](#migrating).
- Copy-paste solutions: [Recipes](#recipes).

<a id="effects"></a>

## Effects
This page covers building effects, chaining them, writing them in direct style with `Fx.gen`, working with time, and running them. An effect (`Effect<A, E>`) is an immutable description of a program that succeeds with a value of type `A` or fails with an error of type `E`. Nothing runs until a fiber interprets it, so the same effect can run many times. Read this page first; [Errors](#errors-and-causes), [Concurrency](#concurrency), [Resources](#scopes-services-layers), [Schedule](#schedule) and [Schema](#schema) build on it.

Examples print values with a `--> result` comment showing what they print.

### How fibers run

A fiber runs one effect. In FiveM, fibers are plain Lua coroutines on a runner inside your resource, not Citizen threads:

- A fiber that waits (`Fx.sleep`, a `Deferred`, a `Queue`, an RPC) is parked and costs nothing per tick. Waking it is a `coroutine.resume`.
- All timers in a resource share one timer heap. A pump thread (rarely two) sleeps until the next timer is due. `Fx.sleep` does not create a Citizen thread.
- `Fx.runFork` and `eff:fork()` do not start the fiber immediately. The fiber starts on the next pass of the runner (the next tick in FiveM).
- `Fx.sleep(0)` and `Fx.yieldNow` give the frame back; the fiber continues on the next tick.
- A fiber that runs more than 2048 interpreter steps without waiting gives the frame back once, then continues on the next tick. Long synchronous chains do not freeze the game, but they also do not finish in one frame.
- A fiber woken by another fiber (a `Queue` offer, a `Deferred` completing) runs once the waking fiber parks, yields or finishes, never in the middle of it.
- Code inside a fiber may still call `Wait`, `Citizen.Wait`, `Citizen.Await` or a yielding native, in `Fx.gen` bodies and in plain `Fx.sync` code. The fiber borrows a Citizen thread for that wait, the wait behaves exactly as on its own thread, and the fiber goes back to the runner the next time it parks.

Prefer `Fx.sleep(ms)` over `Wait(ms)` inside fibers. `Fx.sleep` stays on the runner and can be interrupted at once. A fiber blocked in `Wait` only notices an interruption after the `Wait` returns.

```lua
local stopped = Fx.gen(function()
  Wait(1000)                -- borrows a Citizen thread; not interruptible
  Fx.yield(Fx.sleep(1000))  -- stays on the runner; interruptible
  return 'done'
end)
Fx.runFork(stopped:timeout(500), {
  onExit = function(exit) print(exit._tag, Fx.Cause.failureOption(exit.cause)._tag) end,
})
--> Failure TimeoutError
```

In the example above the timeout fires at 500 ms but the fiber is stuck in `Wait` until 1000 ms, so the `TimeoutError` arrives at 1000 ms, not 500 ms.

### Building effects

#### Fx.succeed(value)

```lua
Fx.succeed(value: A) -> Effect<A, never>
```

- **Parameters:** `value`, any Lua value including `nil`.
- **Returns:** an effect that succeeds with `value`.
- **Fails with:** never.

```lua
local starterCash = Fx.succeed(500)
print(Fx.runSync(starterCash)) --> 500
```

#### Fx.fail(err)

```lua
Fx.fail(err: E) -> Effect<never, E>
```

- **Parameters:** `err`, the expected error. Usually a tagged error (see [Errors](#errors-and-causes)), but any value works.
- **Returns:** an effect that fails with `err`.
- **Fails with:** `err`.
- **Notes:** a tagged error instance has a shortcut: `NotEnoughMoney { need = 50 }:fail()` is the same as `Fx.fail(NotEnoughMoney { need = 50 })`.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local eff = Fx.fail(NotEnoughMoney { need = 50 })
local exit = Fx.runSyncExit(eff)
print(Fx.Cause.failureOption(exit.cause)._tag) --> NotEnoughMoney
```

#### Fx.die(defect)

```lua
Fx.die(defect: any) -> Effect<never, never>
```

- **Parameters:** `defect`, any value describing a bug.
- **Returns:** an effect that fails with a defect (an unexpected error). A Lua traceback of the call site is kept in the cause.
- **Fails with:** a defect, which `catchAll`, `catchTag` and the other expected-error handlers do not catch. See [Errors](#failures-defects-and-interruptions).

```lua
local exit = Fx.runSyncExit(Fx.die('vehicle table corrupted'))
print(Fx.Cause.defects(exit.cause)[1]) --> vehicle table corrupted
```

#### Fx.failCause(cause)

```lua
Fx.failCause(cause: Cause) -> Effect<never, any>
```

- **Parameters:** `cause`, a [Cause](#fxcause).
- **Returns:** an effect that fails with exactly that cause.
- **Fails with:** whatever the cause holds.
- **Notes:** used to re-raise a cause you inspected in `catchAllCause` or `onExit`.

```lua
local eff = Fx.failCause(Fx.Cause.fail('busy'))
print(Fx.Cause.failureOption(Fx.runSyncExit(eff).cause)) --> busy
```

#### Fx.sync(fn)

```lua
Fx.sync(fn: fun(): A) -> Effect<A, never>
```

- **Parameters:** `fn`, a function called with no arguments each time the effect runs.
- **Returns:** an effect that succeeds with the return value of `fn`.
- **Fails with:** never by itself. If `fn` raises a tagged error (`error(NotFound {})`), the effect fails with that error. Any other raised error becomes a defect with a traceback.
- **Notes:** `fn` runs lazily, every time. If `fn` returns an effect, that effect is the success value; it is not run. Use `Fx.suspend` to build an effect lazily.

```lua
local balances = { [1] = 1200 }
local readBalance = Fx.sync(function() return balances[1] end)
balances[1] = 900
print(Fx.runSync(readBalance)) --> 900
```

#### Fx.try(fn, onError?)

```lua
Fx.try(fn: fun(): A, onError?: fun(err: any): TaggedError) -> Effect<A, UnknownError | TaggedError>
```

- **Parameters:** `fn`, called with no arguments when the effect runs. `onError`, optional, maps a raised error to the failure.
- **Returns:** an effect that succeeds with the return value of `fn`.
- **Fails with:** `UnknownError { message = tostring(err), cause = err }` when `fn` raises and `onError` is not given (or returns `nil`/`false`). A raised tagged error is kept as is. With `onError`, the value it returns.
- **Notes:** the value `onError` returns is raised again internally, so it must be a tagged error to become an expected failure. A plain string or table returned by `onError` becomes a defect. The `message` of an `UnknownError` includes Lua's `file:line:` prefix when the error was a string raised with `error('...')`.

```lua
local BadJson = Fx.TaggedError('BadJson')
local decode = function(text)
  return Fx.try(function()
    local v = load('return ' .. text)
    if not v then error('not valid') end
    return v()
  end, function(err) return BadJson { message = tostring(err) } end)
end
local exit = Fx.runSyncExit(decode('{ oops'))
print(Fx.Cause.failureOption(exit.cause)._tag) --> BadJson
print(Fx.runSync(decode('42'))) --> 42
```

#### Fx.suspend(fn)

```lua
Fx.suspend(fn: fun(): Effect<A, E>) -> Effect<A, E>
```

- **Parameters:** `fn`, called each time the effect runs. It must return an effect.
- **Returns:** the effect `fn` returns.
- **Fails with:** whatever the returned effect fails with. A raised tagged error is a failure; another raised error, or a return value that is not an effect, is a defect (`expected an Fx effect but got ...`).
- **Notes:** use it to read mutable state at run time, to branch, and for recursion.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local balances = { [1] = 100 }
local function withdraw(src, amount)
  return Fx.suspend(function()
    local have = balances[src] or 0
    if have < amount then return NotEnoughMoney { have = have, need = amount }:fail() end
    balances[src] = have - amount
    return Fx.succeed(balances[src])
  end)
end
print(Fx.runSync(withdraw(1, 30))) --> 70
print(Fx.runSyncExit(withdraw(1, 500))._tag) --> Failure
```

#### Fx.async(register)

```lua
Fx.async(register: fun(resume: fun(eff: Effect<A, E>)): (fun() | nil)) -> Effect<A, E>
```

- **Parameters:** `register`, called when the effect runs. It receives `resume`. Call `resume(eff)` once with the effect to continue with (`Fx.succeed(v)`, `Fx.fail(e)`). `register` may return a canceler function.
- **Returns:** an effect that waits until `resume` is called, then runs the effect passed to it.
- **Fails with:** whatever the resumed effect fails with. If `register` raises, the effect dies with that error.
- **Notes:** the fiber parks while waiting. `resume` may be called synchronously inside `register`. Only the first call counts. A value passed to `resume` that is not an effect is treated as `Fx.succeed(value)`. If the fiber is interrupted while waiting, the canceler is called (errors in it are ignored) and the fiber is interrupted.

```lua
-- Wrap a callback API: a fake bank export that answers after a delay.
local function bankBalance(src, cb) Fx.runFork(Fx.sleep(50):zipRight(Fx.sync(function() cb(src * 100) end))) end

local balance = function(src)
  return Fx.async(function(resume)
    bankBalance(src, function(amount) resume(Fx.succeed(amount)) end)
  end)
end
Fx.runFork(balance(3), { onExit = function(exit) print(exit.value) end }) --> 300
```

#### Fx.callback(register)

```lua
Fx.callback(register: fun(done: fun(ok: boolean, valueOrError: any)): (fun() | nil)) -> Effect<any, any>
```

- **Parameters:** `register`, receives `done`. Call `done(true, value)` to succeed or `done(false, err)` to fail. It may return a canceler, as with `Fx.async`.
- **Returns:** an effect that waits for `done`.
- **Fails with:** `err` from `done(false, err)`.
- **Notes:** a thin layer over `Fx.async` for node-style callbacks. It is an async effect even when `done` is called synchronously, so it cannot run under `Fx.runSync`.

```lua
local function fetchGarage(src, cb)
  if src == 1 then cb(true, { 'adder', 'zentorno' }) else cb(false, 'no garage') end
end
local garage = function(src)
  return Fx.callback(function(done) fetchGarage(src, done) end)
end
Fx.runFork(garage(1), { onExit = function(exit) print(#exit.value) end }) --> 2
Fx.runFork(garage(2), { onExit = function(exit) print(Fx.Cause.failureOption(exit.cause)) end }) --> no garage
```

#### Fx.fromPromise(p)

```lua
Fx.fromPromise(p: promise) -> Effect<any, any>
```

- **Parameters:** `p`, a Citizen promise (`promise.new()`), or any object with `p:next(onResolve, onReject)`.
- **Returns:** an effect that waits for the promise and succeeds with its value.
- **Fails with:** the rejection value.
- **Notes:** the promise is not cancelled if the fiber is interrupted.

```lua
-- In FiveM: local p = promise.new() ... p:resolve(value)
local p = { next = function(self, ok, fail) ok('Ana') end }
Fx.runFork(Fx.fromPromise(p), { onExit = function(exit) print(exit.value) end }) --> Ana
```

#### Fx.fromNullable(value, onNil?)

```lua
Fx.fromNullable(value: A | nil, onNil?: fun(): E) -> Effect<A, E | NoSuchElementError>
```

- **Parameters:** `value`, any value. `onNil`, optional, returns the error to fail with.
- **Returns:** an effect that succeeds with `value` when it is not `nil`.
- **Fails with:** `onNil()` when given, else `NoSuchElementError {}`.

```lua
local PlayerNotFound = Fx.TaggedError('PlayerNotFound')
local function findName(src)
  return Fx.fromNullable(GetPlayerName(src), function() return PlayerNotFound { src = src } end)
end
print(Fx.runSync(findName(1))) --> Ana
print(Fx.Cause.failureOption(Fx.runSyncExit(findName(99)).cause)._tag) --> PlayerNotFound
```

#### Fx.fromExit(exit)

```lua
Fx.fromExit(exit: Exit<A>) -> Effect<A, any>
```

- **Parameters:** `exit`, an [Exit](#fxexit).
- **Returns:** an effect that succeeds with `exit.value` or fails with `exit.cause`.

```lua
print(Fx.runSync(Fx.fromExit(Fx.Exit.succeed('ok')))) --> ok
```

#### Fx.withFiber(f)

```lua
Fx.withFiber(f: fun(fiber: Fiber): Effect<A, E>) -> Effect<A, E>
```

- **Parameters:** `f`, called with the running [fiber](#fibers); must return an effect.
- **Returns:** the effect `f` returns.
- **Notes:** low level. `Fx.fiberId` covers the common case.

```lua
local eff = Fx.withFiber(function(fiber) return Fx.succeed(type(fiber.id)) end)
print(Fx.runSync(eff)) --> number
```

#### Fx.unit and Fx.void

```lua
Fx.unit: Effect<nil, never>
Fx.void: Effect<nil, never>
```

- **Returns:** an effect that succeeds with `nil`. `Fx.void` is the same value as `Fx.unit`.
- **Notes:** finalizers, `onExit` callbacks and handlers that must return an effect often return `Fx.unit`.

```lua
print(Fx.runSync(Fx.unit)) --> nil
```

#### Fx.never

```lua
Fx.never: Effect<never, never>
```

- **Returns:** an effect that never finishes.
- **Notes:** it parks the fiber forever at no cost. The fiber stops only when interrupted (its parent ends, a timeout, a closed scope, resource stop). Useful to keep a scope open until the resource stops.

```lua
Fx.runFork(Fx.never:timeoutOption(100), { onExit = function(exit) print(exit.value) end }) --> nil
```

#### Fx.yieldNow

```lua
Fx.yieldNow: Effect<nil, never>
```

- **Returns:** an effect that gives the frame back to the game once and succeeds with `nil` on the next tick.
- **Notes:** under `Fx.runSync` it does nothing. Use it inside long loops of work to spread them over frames.

```lua
local function processAll(vehicles)
  return Fx.forEach(vehicles, function(plate, i)
    local step = Fx.sync(function() return plate:upper() end)
    if i % 50 == 0 then return Fx.yieldNow:zipRight(step) end
    return step
  end)
end
Fx.runFork(processAll({ 'ab12', 'cd34' }), { onExit = function(exit) print(exit.value[2]) end }) --> CD34
```

#### Fx.fiberId

```lua
Fx.fiberId: Effect<integer, never>
```

- **Returns:** an effect that succeeds with the id of the fiber running it.
- **Notes:** fiber ids are unique per resource and increase. Effects run by `timeout`, `race`, `forEach` with concurrency and `fork` run on other fibers and see other ids.

```lua
Fx.runFork(Fx.fiberId, { onExit = function(exit) print(math.type(exit.value)) end }) --> integer
```

#### Fx.isEffect(value)

```lua
Fx.isEffect(value: any) -> boolean
```

- **Returns:** `true` when `value` is an effect (including service tags).

```lua
print(Fx.isEffect(Fx.unit), Fx.isEffect(function() end)) --> true false
```

### Chaining

#### eff:map(f)

```lua
eff:map(f: fun(a: A): B) -> Effect<B, E>
```

- **Parameters:** `f`, called with the success value; its return value is the new success value.
- **Returns:** an effect with the mapped value.
- **Fails with:** the errors of `eff`. A tagged error raised in `f` becomes a failure, any other raised error a defect.

```lua
local price = Fx.succeed(1999):map(function(cents) return cents / 100 end)
print(Fx.runSync(price)) --> 19.99
```

#### eff:flatMap(f)

```lua
eff:flatMap(f: fun(a: A): Effect<B, E2>) -> Effect<B, E | E2>
```

- **Parameters:** `f`, called with the success value; must return an effect.
- **Returns:** the effect returned by `f`.
- **Fails with:** the errors of `eff` or of the effect `f` returns. A return value that is not an effect is a defect.
- **Notes:** chains of any length do not grow the Lua stack.

```lua
local function getCash(src) return Fx.succeed(250) end
local function addCash(src, n) return Fx.succeed(250 + n) end
local eff = getCash(1):flatMap(function(cash) return addCash(1, cash) end)
print(Fx.runSync(eff)) --> 500
```

#### eff:andThen(next)

```lua
eff:andThen(next: Effect<B, E2> | fun(a: A): (Effect<B, E2> | B)) -> Effect<B, E | E2>
```

- **Parameters:** `next`, an effect to run after `eff`, or a function of the value that returns an effect or a plain value.
- **Returns:** the next effect, or `Fx.succeed(value)` when the function returns a plain value.
- **Notes:** a mix of `map`, `flatMap` and `zipRight`.

```lua
local eff = Fx.succeed(2):andThen(function(n) return n * 10 end):andThen(Fx.succeed('saved'))
print(Fx.runSync(eff)) --> saved
```

#### eff:tap(f)

```lua
eff:tap(f: fun(a: A): any) -> Effect<A, E>
```

- **Parameters:** `f`, called with the success value. It may return an effect, which runs; any other return value is ignored.
- **Returns:** an effect that keeps the original value.
- **Fails with:** the errors of `eff`, or of the effect `f` returns.

```lua
local eff = Fx.succeed(42):tap(function(n) print('spawned vehicle', n) end)
print(Fx.runSync(eff))
--> spawned vehicle 42
--> 42
```

#### eff:as(value)

```lua
eff:as(value: B) -> Effect<B, E>
```

- **Returns:** an effect that runs `eff` and succeeds with `value` instead.

```lua
print(Fx.runSync(Fx.sync(function() end):as('paid'))) --> paid
```

#### eff:asVoid()

```lua
eff:asVoid() -> Effect<nil, E>
```

- **Returns:** an effect that runs `eff` and succeeds with `nil`.

```lua
print(Fx.runSync(Fx.succeed(5):asVoid())) --> nil
```

#### eff:zip(that)

```lua
eff:zip(that: Effect<B, E2>) -> Effect<{ [1]: A, [2]: B }, E | E2>
```

- **Returns:** an effect that runs `eff`, then `that`, and succeeds with `{ a, b }`.
- **Notes:** sequential. For concurrent runs use [Fx.all](#fxalleffects-opts).

```lua
local pair = Fx.runSync(Fx.succeed('Ana'):zip(Fx.succeed(1500)))
print(pair[1], pair[2]) --> Ana 1500
```

#### eff:zipLeft(that)

```lua
eff:zipLeft(that: Effect<B, E2>) -> Effect<A, E | E2>
```

- **Returns:** an effect that runs `eff`, then `that`, and keeps the value of `eff`.

```lua
local eff = Fx.succeed('veh_42'):zipLeft(Fx.sync(function() print('logged') end))
print(Fx.runSync(eff))
--> logged
--> veh_42
```

#### eff:zipRight(that)

```lua
eff:zipRight(that: Effect<B, E2>) -> Effect<B, E | E2>
```

- **Returns:** an effect that runs `eff`, then `that`, and keeps the value of `that`.

```lua
print(Fx.runSync(Fx.sync(function() end):zipRight(Fx.succeed('next')))) --> next
```

#### eff:filterOrFail(pred, onFalse)

```lua
eff:filterOrFail(pred: fun(a: A): boolean, onFalse: fun(a: A): E2) -> Effect<A, E | E2>
```

- **Parameters:** `pred`, checks the value. `onFalse`, builds the error when `pred` is false.
- **Returns:** an effect with the same value when `pred` holds.
- **Fails with:** `onFalse(a)` when `pred(a)` is false.

```lua
local TooYoung = Fx.TaggedError('TooYoung')
local age = Fx.succeed(16):filterOrFail(function(a) return a >= 18 end, function(a) return TooYoung { age = a } end)
print(Fx.Cause.failureOption(Fx.runSyncExit(age).cause)._tag) --> TooYoung
```

#### eff:forever()

```lua
eff:forever() -> Effect<never, E>
```

- **Returns:** an effect that runs `eff` again after every success, forever.
- **Fails with:** the first failure of `eff`, which stops the loop.
- **Notes:** add a wait (`:delay(ms)`) or the loop only gives the frame back every 2048 steps. For a counted or timed loop use [repeatWith](#effrepeatwithschedule).

```lua
local ticks = 0
local loop = Fx.sync(function() ticks = ticks + 1 end):delay(1000):forever()
Fx.runFork(loop:timeoutOption(3500), { onExit = function() print(ticks) end }) --> 3
```

Error handling (`catchAll`, `catchTag`, `mapError`, `result`, `match` and the rest) is on the [Errors](#errors-and-causes) page. Finalizers (`ensuring`, `onExit`, `onError`, `onInterrupt`) are on the [Resources](#scopes-services-layers) page.

### Direct style with Fx.gen

#### Fx.gen(body, ...)

```lua
Fx.gen(body: fun(...): A, ...: any) -> Effect<A, any>
```

- **Parameters:** `body`, a function written in direct style. Extra arguments are passed to `body`.
- **Returns:** an effect that runs `body` in a new coroutine each time it runs, and succeeds with what `body` returns. Only the first return value is kept; return a table for several.
- **Fails with:** the cause of the first `Fx.yield` whose effect fails (the rest of `body` does not run). A tagged error raised with `error(MyError {})` is a failure; any other raised error (including Lua runtime errors) is a defect with a traceback.
- **Notes:**
  - `Wait`, `Citizen.Wait` and `Citizen.Await` work inside `body` (see [How fibers run](#how-fibers-run)). Under `Fx.runSync` they are a defect.
  - When the fiber is interrupted while `body` is suspended, the coroutine is closed: code after the pending `Fx.yield` does not run, and to-be-closed variables (`<close>`) are closed.
  - `pcall` inside `body` does not catch effect failures. When a yielded effect fails, `body` is never resumed, so a `pcall` around `Fx.yield` never returns. Handle errors on the effect instead: `Fx.yield(eff:result())`.
  - Calling `Fx.yield` from a nested coroutine is a Lua error. Calling it from a plain function called by `body` is fine.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local balances = { [1] = 800 }
local getBalance = function(src) return Fx.sync(function() return balances[src] or 0 end) end
local setBalance = function(src, v) return Fx.sync(function() balances[src] = v end) end

local function buyVehicle(src, price)
  return Fx.gen(function()
    local have = Fx.yield(getBalance(src))
    if have < price then error(NotEnoughMoney { have = have, need = price }) end
    Fx.yield(setBalance(src, have - price))
    return have - price
  end)
end

print(Fx.runSync(buyVehicle(1, 300))) --> 500
local r = Fx.runSync(buyVehicle(1, 9000):result())
print(r.ok, r.error._tag, r.error.have) --> false NotEnoughMoney 500
```

#### Fx.yield(eff)

```lua
Fx.yield(eff: Effect<A, E>) -> A
```

- **Parameters:** `eff`, the effect to run.
- **Returns:** the success value of `eff`, inside an `Fx.gen` body.
- **Fails with:** on failure the `Fx.gen` stops at this point and fails with the same cause.
- **Notes:** outside `Fx.gen` it raises `Fx.yield called outside Fx.gen ...`. Yielding something that is not an effect makes the gen die with `Fx.yield expects an effect, got <type>`. Yield a [service tag](#fxtagkey) to get the service.

```lua
local eff = Fx.gen(function()
  local a = Fx.yield(Fx.succeed(2))
  local b = Fx.yield(Fx.succeed(3):delay(100))
  return a * b
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> 6
```

#### eff:await()

```lua
eff:await() -> A
```

- **Returns:** the same as `Fx.yield(eff)`. Method form, only inside `Fx.gen`.

```lua
local eff = Fx.gen(function()
  local name = Fx.succeed('Ana'):await()
  return 'Hello ' .. name
end)
print(Fx.runSync(eff)) --> Hello Ana
```

### Time

Delays are in milliseconds and use the game timer (`GetGameTimer`).

#### Fx.sleep(ms)

```lua
Fx.sleep(ms: integer) -> Effect<nil, never>
```

- **Parameters:** `ms`, delay in milliseconds. `0`, negative values and NaN mean "next tick".
- **Returns:** an effect that succeeds with `nil` after `ms`.
- **Notes:** the fiber parks on the shared timer heap. Interruption cancels the timer at once.

```lua
local respawn = Fx.sleep(5000):zipRight(Fx.sync(function() print('respawned') end))
Fx.runFork(respawn) --> respawned
```

#### eff:delay(ms)

```lua
eff:delay(ms: integer) -> Effect<A, E>
```

- **Returns:** an effect that waits `ms`, then runs `eff`.

```lua
Fx.runFork(Fx.succeed('engine on'):delay(1500), { onExit = function(exit) print(exit.value) end }) --> engine on
```

#### eff:timeout(ms)

```lua
eff:timeout(ms: integer) -> Effect<A, E | TimeoutError>
```

- **Parameters:** `ms`, the time limit.
- **Returns:** an effect with the value of `eff` when it finishes in time.
- **Fails with:** `TimeoutError { timeoutMs = ms }` when the time runs out; the errors of `eff` when it fails first.
- **Notes:** `eff` runs on a child fiber. When the time runs out, `eff` is interrupted and its finalizers run before the timeout error is raised. If `eff` is in an uninterruptible region, the timeout waits for that region to end. Whichever finishes first decides, so an early failure of `eff` wins over the timer.

```lua
local loadModel = Fx.sleep(8000):as('adder')
Fx.runFork(loadModel:timeout(5000), {
  onExit = function(exit)
    local e = Fx.Cause.failureOption(exit.cause)
    print(e._tag, e.timeoutMs)
  end,
})
--> TimeoutError 5000
```

#### eff:timeoutFail(ms, onTimeout)

```lua
eff:timeoutFail(ms: integer, onTimeout: fun(): E2) -> Effect<A, E | E2>
```

- **Parameters:** `ms`, the time limit. `onTimeout`, builds the error.
- **Fails with:** `onTimeout()` when the time runs out.
- **Notes:** same interruption behaviour as `timeout`.

```lua
local BankDown = Fx.TaggedError('BankDown')
local call = Fx.never:timeoutFail(3000, function() return BankDown { message = 'bank did not answer' } end)
Fx.runFork(call, { onExit = function(exit) print(tostring(Fx.Cause.failureOption(exit.cause))) end })
--> BankDown: bank did not answer
```

#### eff:timeoutOption(ms)

```lua
eff:timeoutOption(ms: integer) -> Effect<A | nil, E>
```

- **Returns:** an effect that succeeds with the value of `eff`, or with `nil` when the time runs out.
- **Notes:** a `TimeoutError` raised by `eff` itself also becomes `nil`, because it is caught by tag.

```lua
local waitForPlayer = Fx.sleep(10000):as(3)
Fx.runFork(waitForPlayer:timeoutOption(2000), { onExit = function(exit) print(exit.value) end }) --> nil
```

#### eff:retry(policy)

```lua
eff:retry(policy: integer | Schedule | RetryPolicy) -> Effect<A, E>
```

- **Parameters:** `policy`, a number of retries, a [Schedule](#schedule), or a table `{ times?, schedule?, while?, until? }`.
- **Returns:** an effect that runs `eff` again after each expected failure, as the policy allows.
- **Fails with:** the last error when the policy stops. Defects and interruptions are not retried.
- **Notes:** full details on the [Schedule](#effretrypolicy) page.

```lua
local attempts = 0
local flakyDb = Fx.suspend(function()
  attempts = attempts + 1
  if attempts < 3 then return Fx.fail('deadlock') end
  return Fx.succeed('row saved')
end)
Fx.runFork(flakyDb:retry(Fx.Schedule.exponential(100):take(5)), {
  onExit = function(exit) print(exit.value, attempts) end,
})
--> row saved 3
```

#### eff:repeatWith(schedule)

```lua
eff:repeatWith(schedule: Schedule | integer) -> Effect<A, E>
```

- **Returns:** an effect that runs `eff`, then runs it again after each success as the schedule allows, and succeeds with the last value.
- **Fails with:** the first failure, which stops the repeat.
- **Notes:** `eff['repeat'](eff, schedule)` is the same function (`repeat` is a Lua keyword). `eff:repeatN(n)` runs `eff` `n + 1` times. Details on the [Schedule](#effrepeatwithschedule) page.

```lua
local saves = 0
local autosave = Fx.sync(function() saves = saves + 1 end):repeatWith(Fx.Schedule.spaced(60000):take(2))
Fx.runFork(autosave, { onExit = function() print(saves) end }) --> 3
```

#### Fx.poll(check, timeout, onTimeout)

```lua
Fx.poll(check: fun(): boolean, timeout: integer, onTimeout: fun(): E) -> Effect<nil, E>
```

- **Parameters:** `check`, called once per tick until it returns true. `timeout`, the time limit in ms. `onTimeout`, builds the error.
- **Returns:** an effect that succeeds with `nil` once `check()` is true.
- **Fails with:** `onTimeout()` after `timeout` ms.
- **Notes:** `Fx.poll` is defined by the assets module, so it is `nil` until `Fx.assets` has been accessed once in the resource. Touch `Fx.assets` first (`local _ = Fx.assets`). For loading game assets use [Fx.assets](#players-config-assets-entities) directly.

```lua
local _ = Fx.assets -- loads the module that defines Fx.poll
local ready = false
Fx.runFork(Fx.sync(function() ready = true end):delay(300))
local NotReady = Fx.TaggedError('NotReady')
Fx.runFork(Fx.poll(function() return ready end, 1000, function() return NotReady {} end), {
  onExit = function(exit) print(exit._tag) end,
})
--> Success
```

### Running effects

Every `run*` function accepts an optional `opts.context` table (tag to service) that becomes the fiber's initial services. Most code uses [Runtime](#runtime) or `eff:provide(layer)` instead.

#### Fx.runFork(eff, opts?)

```lua
Fx.runFork(eff: Effect<A, E>, opts?: { onExit?: fun(exit: Exit<A>), context?: table }) -> Fiber
```

- **Parameters:** `eff`, the effect. `opts.onExit`, called with the [Exit](#fxexit) when the fiber ends. `opts.context`, initial services.
- **Returns:** the new root [fiber](#fibers), right away. It starts on the next tick.
- **Fails with:** nothing is raised. Without `onExit`, a failure that is not only an interruption is logged as an error (`Unhandled failure in fiber #<id>`, with the pretty cause) and shows in `/fxdev`. With `onExit`, nothing is logged; handling is up to you.
- **Notes:** the fiber is interrupted when the resource stops. This is the usual way to start effects from event handlers and resource start.

```lua
local fiber = Fx.runFork(Fx.succeed('ready'):delay(100), {
  onExit = function(exit) print(exit._tag, exit.value) end,
})
print(fiber.exit) -- not started yet
--> nil
--> Success ready
```

#### Fx.runCallback(eff, cb, opts?)

```lua
Fx.runCallback(eff: Effect<A, E>, cb: fun(exit: Exit<A>), opts?: { context?: table }) -> Fiber
```

- **Returns:** the fiber. Same as `Fx.runFork(eff, { onExit = cb, context = opts.context })`.

```lua
Fx.runCallback(Fx.fail('no vehicle'), function(exit)
  print(exit._tag, Fx.Cause.failureOption(exit.cause))
end)
--> Failure no vehicle
```

#### Fx.runAwait(eff, opts?)

```lua
Fx.runAwait(eff: Effect<A, E>, opts?: { context?: table }) -> A
```

- **Parameters:** `eff`, the effect.
- **Returns:** the success value. The calling Citizen thread is suspended until the effect finishes.
- **Fails with:** raises with `error(value, 0)`, so `pcall` works: the error itself for an expected failure, the defect for a defect (a string defect gets its traceback appended), or a table `{ _tag = 'Interrupted', _fxCause = cause }` for an interruption.
- **Notes:** call it from a Citizen thread (a `CreateThread` body or an event handler), where `Citizen.Await` would also work. The effect runs on its own root fiber, interrupted on resource stop. This is the entry point for existing code that does not use effects yet.

```lua
CreateThread(function()
  local price = Fx.runAwait(Fx.succeed(25000):delay(200))
  print('price', price)
  local ok, err = pcall(Fx.runAwait, Fx.fail('garage full'))
  print(ok, err)
end)
--> price 25000
--> false garage full
```

#### Fx.runSync(eff, opts?)

```lua
Fx.runSync(eff: Effect<A, E>, opts?: { context?: table }) -> A
```

- **Returns:** the success value, computed right now on the calling thread.
- **Fails with:** raises like `Fx.runAwait`. An effect that needs to wait (`Fx.sleep`, `Fx.async`, `Deferred:await`, a `Wait` inside `Fx.gen`) dies with `Fx.runSync hit an async effect. Use Fx.runFork or Fx.runAwait instead.` (or the `Citizen.Wait/Await` variant), which is raised.
- **Notes:** for pure computations, schema decoding and tests. Any `Fx.async` step is rejected, even one whose callback answers synchronously, so `Fx.callback`, `Fx.fromPromise`, `Deferred:await`, `Queue:take`, `Semaphore` permits, `timeout`, `race` and concurrent `forEach` cannot run here. `Fx.yieldNow` does nothing here. Forked fibers start later on the runner as usual.

```lua
print(Fx.runSync(Fx.succeed(2):map(function(x) return x * 2 end))) --> 4
local ok, err = pcall(Fx.runSync, Fx.sleep(10))
print(ok, err) --> false Fx.runSync hit an async effect. Use Fx.runFork or Fx.runAwait instead.
```

#### Fx.runSyncExit(eff, opts?)

```lua
Fx.runSyncExit(eff: Effect<A, E>, opts?: { context?: table }) -> Exit<A>
```

- **Returns:** the [Exit](#fxexit) of running `eff` synchronously. Never raises for effect failures.

```lua
local exit = Fx.runSyncExit(Fx.fail('no license'))
print(exit._tag, Fx.Cause.failureOption(exit.cause)) --> Failure no license
```

#### Fx.setRuntime(rt)

```lua
Fx.setRuntime(rt: Runtime) -> nil
```

- **Parameters:** `rt`, a [Runtime](#runtime).
- **Notes:** makes `rt` the default runtime for `Fx.net` handlers, `Fx.rpc` handlers and the `Fx.compat` ox_lib bridge in this resource, so their handlers can yield the runtime's services. It does not affect `Fx.runFork`, `Fx.runAwait` or `Fx.runSync`; use `rt:runFork(eff)` for those. A per-handler `runtime` option overrides it (see [Net and RPC](#net-events-and-rpc)).

```lua
local Bank = Fx.Tag('Bank')
Fx.setRuntime(Fx.Runtime.make(Fx.Layer.succeed(Bank, { name = 'Maze Bank' })))
-- Fx.rpc.register(...) handlers can now Fx.yield(Bank).
```

#### Fx.setPlatform(p) and Fx.getPlatform()

```lua
Fx.setPlatform(p: table) -> nil
Fx.getPlatform() -> table
```

- **Notes:** swap the scheduler under the runtime. The repository's test runner (`lua5.4 tests/run.lua`) uses a virtual-clock platform from `tests/platform.lua`, so effects with `Fx.sleep` run instantly in tests. Game code never needs this.

```lua
-- In a test file run by tests/run.lua:
-- local Fx, p = T.fresh()                 -- fresh Fx on the virtual platform
-- local v = T.run(Fx, p, Fx.succeed(1):delay(5000))
-- assert(v == 1 and p.now() == 5000)
print(Fx.getPlatform().name) --> virtual
```

<a id="errors-and-causes"></a>

## Errors and causes
This page covers typed errors (`Fx.TaggedError`), the operators that recover from or transform errors, the difference between failures, defects and interruptions, and the `Fx.Cause` and `Fx.Exit` values that describe how an effect ended. Use tagged errors for every failure a caller may want to handle, and let bugs stay defects. The catalogue of tags raised by the FiveM modules is on the [Errors catalogue](#errors-and-gotchas) page.

Examples print values with a `--> result` comment showing what they print.

### Failures, defects and interruptions

An effect that does not succeed ends with a **cause**, which holds one or more of these:

| Kind | Made by | Caught by `catchAll`, `catchTag`, `mapError`, `result`, ... | Caught by `catchAllCause` |
|---|---|---|---|
| Failure (expected error) | `Fx.fail(e)`, `MyError {}:fail()`, `error(MyError {})` inside effect code, `Fx.try` | yes | yes |
| Defect (bug) | `Fx.die(x)`, any other Lua error raised inside effect code, a missing service, `Fx.runSync` hitting an async step | no | yes |
| Interruption | `fiber:interrupt()`, a timeout or race loser, a parent ending, a scope closing, resource stop | no | yes, but not while the fiber itself is being interrupted |

Rules that follow from the code:

- Raising inside effect code is safe. In `Fx.sync`, `Fx.suspend`, `Fx.gen` bodies and the callbacks of `map`, `flatMap`, `tap` and friends, a raised **tagged error** becomes a failure with that error. Anything else raised becomes a defect, with a Lua traceback kept in the cause.
- The expected-error handlers act only when the cause holds at least one failure and **no defects**. A cause that mixes a failure and a defect (for example a failing effect whose finalizer also crashed) passes through them untouched.
- When a fiber is being interrupted, only finalizers run (`onExit`, `ensuring`, `acquireRelease` releases, scope finalizers). Recovery handlers, including `catchAllCause`, are skipped, so an interruption cannot be swallowed. An interruption cause received from *another* fiber (for example through `fiber:join()` on an interrupted fiber) is a normal cause and `catchAllCause` can handle it.
- Defects and interruptions are never retried by `retry`.

### Tagged errors

#### Fx.TaggedError(tag, fields?)

```lua
Fx.TaggedError(tag: string, fields?: table<string, Schema>) -> TaggedErrorClass
```

- **Parameters:** `tag`, the name stored in `_tag`. `fields`, optional table of [schemas](#schema) checked every time an instance is built.
- **Returns:** a class. Call it with a table of fields to build an instance: `NotEnoughMoney { have = 10, need = 50 }`.
- **Fails with:** building an instance with `fields` that do not match raises `invalid fields for <tag>: <message>` at the call site (a plain Lua error, so inside effect code it becomes a defect).
- **Notes:**
  - An instance is a plain table: your fields copied, plus `_tag = tag` and an internal `_fxTagged = true` marker. Its metatable gives it `:fail()` and a `tostring`: `"<tag>: <message>"` when it has a non-empty string `message` field, otherwise an inspect-style rendering such as `NotEnoughMoney { have = 10, need = 50 }`.
  - The class has `cls._tag` and `cls.is(value)`. `tostring(cls)` is `TaggedError(<tag>)`.
  - Tags are compared by name. Two classes with the same tag match the same `catchTag`.
  - The field check uses `Fx.S.struct(fields)` in its default mode, so extra fields are allowed and are not stripped.
  - Instances survive the network: use [Fx.serializeError](#fxserializeerrorerr) and [Fx.taggedFromTable](#fxtaggedfromtablet). `Fx.rpc` does this for you.

```lua
local S = Fx.S
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney', { have = S.number, need = S.number })
local VehicleLocked = Fx.TaggedError('VehicleLocked')

local e = NotEnoughMoney { have = 10, need = 50 }
print(e._tag, e.need) --> NotEnoughMoney 50
print(tostring(e)) --> NotEnoughMoney { have = 10, need = 50 }
print(tostring(VehicleLocked { message = 'plate ABC123' })) --> VehicleLocked: plate ABC123
print(NotEnoughMoney.is(e), VehicleLocked.is(e)) --> true false
print(pcall(NotEnoughMoney, { have = 'lots' })) --> false invalid fields for NotEnoughMoney: have: expected number, got "lots"
```

#### err:fail()

```lua
err:fail() -> Effect<never, TaggedError>
```

- **Returns:** `Fx.fail(err)`.

```lua
local PlayerNotFound = Fx.TaggedError('PlayerNotFound')
local function getPlayer(src)
  if not GetPlayerName(src) then return PlayerNotFound { src = src }:fail() end
  return Fx.succeed({ src = src, name = GetPlayerName(src) })
end
print(Fx.runSync(getPlayer(1)).name) --> Ana
print(Fx.runSyncExit(getPlayer(42))._tag) --> Failure
```

#### error(TaggedError) inside effect code

```lua
error(err: TaggedError) -> never -- inside Fx.gen, Fx.sync, Fx.suspend, map, flatMap, tap, ...
```

- **Notes:** raising a tagged error fails the surrounding effect with that error, as if the code returned `err:fail()`. This lets helper functions called from a gen body stop it with a typed error. Raising anything else (a string, a plain table, a Lua runtime error) is a defect.

```lua
local InvalidPlate = Fx.TaggedError('InvalidPlate')
local function checkPlate(plate)
  if #plate > 8 then error(InvalidPlate { plate = plate }) end
  return plate:upper()
end
local register = function(plate) return Fx.gen(function() return checkPlate(plate) end) end
print(Fx.runSync(register('abc123'))) --> ABC123
local exit = Fx.runSyncExit(register('TOOLONGPLATE'))
print(Fx.Cause.failureOption(exit.cause)._tag) --> InvalidPlate
local bug = Fx.runSyncExit(Fx.sync(function() local car = nil; return car.model end))
print(#Fx.Cause.failures(bug.cause), #Fx.Cause.defects(bug.cause)) --> 0 1
```

### Recovering from errors

All of these take a handler that **must return an effect**. Returning a plain value from the handler is a defect (`expected an Fx effect but got ...`), except where noted.

#### eff:catchAll(f)

```lua
eff:catchAll(f: fun(err: E): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Parameters:** `f`, called with the first expected error.
- **Returns:** the effect `f` returns when `eff` fails with an expected error.
- **Fails with:** whatever `f`'s effect fails with. Defects and interruptions pass through.

```lua
local loadGarage = Fx.fail('db offline'):catchAll(function(err)
  print('using cache because', err)
  return Fx.succeed({ 'adder' })
end)
print(Fx.runSync(loadGarage)[1])
--> using cache because db offline
--> adder
```

#### eff:catchTag(tag, f)

```lua
eff:catchTag(tag: string, f: fun(err: TaggedError): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Parameters:** `tag`, the `_tag` to match. `f`, the handler.
- **Returns:** the handler's effect when the first expected error is a table with `_tag == tag`.
- **Fails with:** other errors unchanged, plus whatever the handler fails with.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local buy = NotEnoughMoney { have = 20 }:fail()
  :catchTag('NotEnoughMoney', function(e) return Fx.succeed('only $' .. e.have) end)
print(Fx.runSync(buy)) --> only $20
```

#### eff:catchTags(handlers)

```lua
eff:catchTags(handlers: table<string, fun(err: TaggedError): Effect<B, E2>>) -> Effect<A | B, E2>
```

- **Parameters:** `handlers`, a table from tag to handler.
- **Returns:** the matching handler's effect.
- **Fails with:** errors with no matching handler, unchanged.

```lua
local NotFound = Fx.TaggedError('NotFound')
local Busy = Fx.TaggedError('Busy')
local function lookup(which)
  return (which == 1 and NotFound {} or Busy {}):fail():catchTags {
    NotFound = function() return Fx.succeed('no such vehicle') end,
    Busy = function() return Fx.succeed('try again') end,
  }
end
print(Fx.runSync(lookup(1)), Fx.runSync(lookup(2))) --> no such vehicle try again
```

#### eff:catchIf(pred, f)

```lua
eff:catchIf(pred: fun(err: E): boolean, f: fun(err: E): Effect<B, E2>) -> Effect<A | B, E | E2>
```

- **Returns:** the handler's effect when `pred(err)` is true for the first expected error.

```lua
local eff = Fx.fail({ code = 503 }):catchIf(function(e) return e.code >= 500 end, function()
  return Fx.succeed('server error, retry later')
end)
print(Fx.runSync(eff)) --> server error, retry later
```

#### eff:catchAllCause(f)

```lua
eff:catchAllCause(f: fun(cause: Cause): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Parameters:** `f`, called with the full [Cause](#fxcause): failures, defects or interruptions received from another fiber.
- **Notes:** skipped while the fiber itself is being interrupted. Use it at boundaries that must never fail (event handlers, logging wrappers).

```lua
local eff = Fx.die('nil vehicle'):catchAllCause(function(cause)
  print(Fx.Cause.pretty(cause):match('^[^\n]*'))
  return Fx.unit
end)
Fx.runSync(eff)
--> Defect: nil vehicle
```

#### eff:catchAllDefect(f)

```lua
eff:catchAllDefect(f: fun(defect: any): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Parameters:** `f`, called with the first defect.
- **Returns:** the handler's effect when the cause has a defect. Causes without defects pass through.

```lua
local eff = Fx.sync(function() error('native returned nil') end):catchAllDefect(function(d)
  return Fx.succeed('recovered')
end)
print(Fx.runSync(eff)) --> recovered
```

#### eff:mapError(f)

```lua
eff:mapError(f: fun(err: E): E2) -> Effect<A, E2>
```

- **Parameters:** `f`, maps the error to a new error. It returns a plain value, not an effect.
- **Fails with:** `f(err)`. Defects and interruptions pass through.

```lua
local DbError = Fx.TaggedError('DbError')
local eff = Fx.fail('ER_LOCK_DEADLOCK'):mapError(function(code) return DbError { code = code } end)
print(Fx.Cause.failureOption(Fx.runSyncExit(eff).cause).code) --> ER_LOCK_DEADLOCK
```

#### eff:tapError(f)

```lua
eff:tapError(f: fun(err: E): any) -> Effect<A, E>
```

- **Parameters:** `f`, called with the expected error. If it returns an effect, that effect runs first; any other return value is ignored.
- **Fails with:** the original error (or the error of `f`'s effect, if that fails).

```lua
local eff = Fx.fail('card declined'):tapError(function(e) print('payment failed:', e) end)
print(Fx.runSyncExit(eff)._tag)
--> payment failed: card declined
--> Failure
```

#### eff:tapErrorCause(f)

```lua
eff:tapErrorCause(f: fun(cause: Cause): any) -> Effect<A, E>
```

- **Notes:** like `tapError`, with the full cause, for any non-success (failure, defect or received interruption). Skipped while the fiber itself is being interrupted.

```lua
local eff = Fx.die('bad state'):tapErrorCause(function(c) print(#Fx.Cause.defects(c)) end)
print(Fx.runSyncExit(eff)._tag)
--> 1
--> Failure
```

#### eff:orElse(f)

```lua
eff:orElse(f: fun(): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Returns:** the effect `f()` returns when `eff` fails with an expected error. `f` gets no arguments.

```lua
local primary = Fx.fail('primary garage full')
local backup = function() return Fx.succeed('parked at backup garage') end
print(Fx.runSync(primary:orElse(backup))) --> parked at backup garage
```

#### eff:orElseSucceed(value)

```lua
eff:orElseSucceed(value: B) -> Effect<A | B, never>
```

- **Returns:** an effect that succeeds with `value` when `eff` fails with an expected error.

```lua
print(Fx.runSync(Fx.fail('no job'):orElseSucceed('unemployed'))) --> unemployed
```

#### eff:orDie()

```lua
eff:orDie() -> Effect<A, never>
```

- **Returns:** an effect whose expected errors become defects (the error value is the defect).
- **Notes:** use it when a failure here can only mean a bug, for example config that was already validated.

```lua
local exit = Fx.runSyncExit(Fx.fail('config missing'):orDie())
print(#Fx.Cause.failures(exit.cause), Fx.Cause.defects(exit.cause)[1]) --> 0 config missing
```

#### eff:result()

```lua
eff:result() -> Effect<{ ok: true, value: A } | { ok: false, error: E }, never>
```

- **Returns:** an effect that always succeeds with a result table. Defects and interruptions still propagate.
- **Notes:** the easiest way to branch on an error inside `Fx.gen`.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local eff = Fx.gen(function()
  local r = Fx.yield(NotEnoughMoney { need = 100 }:fail():result())
  if not r.ok then return 'missing $' .. r.error.need end
  return r.value
end)
print(Fx.runSync(eff)) --> missing $100
```

#### eff:option()

```lua
eff:option() -> Effect<A | nil, never>
```

- **Returns:** an effect that succeeds with the value, or `nil` on an expected failure.

```lua
print(Fx.runSync(Fx.fail('no vehicle'):option())) --> nil
```

#### eff:exit()

```lua
eff:exit() -> Effect<Exit<A>, never>
```

- **Returns:** an effect that succeeds with the [Exit](#fxexit) of `eff`, for any outcome including defects.
- **Notes:** an interruption of the fiber running it still propagates.

```lua
local exit = Fx.runSync(Fx.die('oops'):exit())
print(exit._tag) --> Failure
```

#### eff:match(handlers)

```lua
eff:match(handlers: { onFailure: fun(err: E): B, onSuccess: fun(a: A): B }) -> Effect<B, never>
```

- **Parameters:** `onFailure` and `onSuccess` return plain values.
- **Returns:** an effect with the value of the handler that ran.
- **Notes:** only expected failures reach `onFailure`; defects and interruptions propagate.

```lua
local label = Fx.fail('locked'):match {
  onFailure = function(e) return 'Vehicle ' .. e end,
  onSuccess = function() return 'Vehicle open' end,
}
print(Fx.runSync(label)) --> Vehicle locked
```

#### eff:matchEffect(handlers)

```lua
eff:matchEffect(handlers: { onFailure: fun(err: E): Effect<B, E2>, onSuccess: fun(a: A): Effect<B, E2> }) -> Effect<B, E2>
```

- **Parameters:** both handlers return effects.

```lua
local eff = Fx.succeed(3):matchEffect {
  onFailure = function() return Fx.succeed(0) end,
  onSuccess = function(n) return Fx.succeed(n * 1000) end,
}
print(Fx.runSync(eff)) --> 3000
```

#### eff:foldCauseEffect(onFailure, onSuccess)

```lua
eff:foldCauseEffect(onFailure: fun(cause: Cause): Effect<B, E2>, onSuccess?: fun(a: A): Effect<B, E2>) -> Effect<B, E2>
```

- **Parameters:** `onFailure` gets the full cause. `onSuccess` may be `nil` to keep the value.
- **Notes:** the primitive the other handlers are built on. Skipped while the fiber itself is being interrupted.

```lua
local eff = Fx.fail('x'):foldCauseEffect(function(c) return Fx.succeed('cause had ' .. #Fx.Cause.failures(c) .. ' failure') end)
print(Fx.runSync(eff)) --> cause had 1 failure
```

Finalizers that observe errors without recovering (`onError`, `onExit`, `ensuring`, `onInterrupt`) are on the [Resources](#scopes-services-layers) page.

### Fx.Cause

A cause is a plain table with a `_tag`:

| `_tag` | Fields |
|---|---|
| `'Empty'` | none |
| `'Fail'` | `error` |
| `'Die'` | `defect`, `trace` (string or nil) |
| `'Interrupt'` | `fiberId` (the interrupting fiber's id; `0` for resource stop and scope closing) |
| `'Sequential'` | `left`, `right` (one thing happened, then another, for example a failure and then a failing finalizer) |
| `'Parallel'` | `left`, `right` (concurrent failures, for example both sides of a `race`) |

#### Fx.Cause.fail(err)

```lua
Fx.Cause.fail(err: any) -> Cause
```

- **Returns:** `{ _tag = 'Fail', error = err }`.

```lua
print(Fx.Cause.fail('x')._tag) --> Fail
```

#### Fx.Cause.die(defect, trace?)

```lua
Fx.Cause.die(defect: any, trace?: string) -> Cause
```

- **Returns:** `{ _tag = 'Die', defect = defect, trace = trace }`.

```lua
print(Fx.Cause.die('bug').defect) --> bug
```

#### Fx.Cause.interrupt(fiberId?)

```lua
Fx.Cause.interrupt(fiberId?: integer) -> Cause
```

- **Returns:** `{ _tag = 'Interrupt', fiberId = fiberId }`.

```lua
print(Fx.Cause.isInterrupted(Fx.Cause.interrupt(7))) --> true
```

#### Fx.Cause.sequential(left, right) and Fx.Cause.parallel(left, right)

```lua
Fx.Cause.sequential(left: Cause, right: Cause) -> Cause
Fx.Cause.parallel(left: Cause, right: Cause) -> Cause
```

- **Returns:** the combined cause. If one side is `Fx.Cause.empty`, the other side is returned as is.

```lua
local c = Fx.Cause.sequential(Fx.Cause.fail('a'), Fx.Cause.die('b'))
print(c._tag, #Fx.Cause.failures(c), #Fx.Cause.defects(c)) --> Sequential 1 1
```

#### Fx.Cause.empty

```lua
Fx.Cause.empty: Cause -- { _tag = 'Empty' }
```

```lua
print(Fx.Cause.parallel(Fx.Cause.empty, Fx.Cause.fail('x'))._tag) --> Fail
```

#### Fx.Cause.failures(cause)

```lua
Fx.Cause.failures(cause: Cause) -> any[]
```

- **Returns:** every expected error in the cause, left to right.

```lua
local c = Fx.Cause.parallel(Fx.Cause.fail('a'), Fx.Cause.fail('b'))
print(table.concat(Fx.Cause.failures(c), ',')) --> a,b
```

#### Fx.Cause.failureOption(cause)

```lua
Fx.Cause.failureOption(cause: Cause) -> any | nil
```

- **Returns:** the first expected error, or `nil`.

```lua
print(Fx.Cause.failureOption(Fx.Cause.die('x'))) --> nil
```

#### Fx.Cause.defects(cause)

```lua
Fx.Cause.defects(cause: Cause) -> any[]
```

- **Returns:** every defect value, left to right.

```lua
print(#Fx.Cause.defects(Fx.Cause.die('x'))) --> 1
```

#### Fx.Cause.isInterrupted(cause)

```lua
Fx.Cause.isInterrupted(cause: Cause) -> boolean
```

- **Returns:** `true` when the cause holds at least one interruption.

```lua
print(Fx.Cause.isInterrupted(Fx.Cause.fail('x'))) --> false
```

#### Fx.Cause.isInterruptedOnly(cause)

```lua
Fx.Cause.isInterruptedOnly(cause: Cause) -> boolean
```

- **Returns:** `true` when the cause holds interruptions and nothing else. Unhandled-failure logging skips these.

```lua
local c = Fx.Cause.sequential(Fx.Cause.interrupt(1), Fx.Cause.die('finalizer crashed'))
print(Fx.Cause.isInterrupted(c), Fx.Cause.isInterruptedOnly(c)) --> true false
```

#### Fx.Cause.squash(cause)

```lua
Fx.Cause.squash(cause: Cause) -> any
```

- **Returns:** the first failure; else the first defect; else the string `'interrupted'`; else `'empty cause'`.

```lua
print(Fx.Cause.squash(Fx.Cause.interrupt(3))) --> interrupted
```

#### Fx.Cause.pretty(cause)

```lua
Fx.Cause.pretty(cause: Cause) -> string
```

- **Returns:** one line per node: `Fail: <error>`, `Defect: <defect>` followed by its traceback lines when there is one, `Interrupted by fiber #<id>` (or `Interrupted` without an id).
- **Notes:** errors are rendered with their `tostring` when they have one, with `Fx.inspect` when they are tables with a `_tag`, else with `tostring`.

```lua
local NoKeys = Fx.TaggedError('NoKeys')
print(Fx.Cause.pretty(Fx.Cause.sequential(Fx.Cause.fail(NoKeys { plate = 'ABC' }), Fx.Cause.interrupt(4))))
--> Fail: NoKeys { plate = "ABC" }
--> Interrupted by fiber #4
```

The example prints one string with a newline in it; the two `-->` lines are its two lines.

#### Fx.Cause.describe(value)

```lua
Fx.Cause.describe(value: any) -> string
```

- **Returns:** the rendering `pretty` uses for one error or defect.

```lua
print(Fx.Cause.describe({ _tag = 'Busy', retryIn = 5 })) --> Busy { retryIn = 5 }
```

#### Fx.Cause.walk(cause, fn)

```lua
Fx.Cause.walk(cause: Cause, fn: fun(node: Cause)) -> nil
```

- **Notes:** calls `fn` for every `Fail`, `Die` and `Interrupt` node, left to right.

```lua
local tags = {}
Fx.Cause.walk(Fx.Cause.parallel(Fx.Cause.fail('a'), Fx.Cause.interrupt(1)), function(n) tags[#tags + 1] = n._tag end)
print(table.concat(tags, ' ')) --> Fail Interrupt
```

### Fx.Exit

An exit is how a fiber ended: `{ _tag = 'Success', value = v }` or `{ _tag = 'Failure', cause = c }`. You get one from `Fx.runFork` / `Fx.runCallback` `onExit`, `Fx.runSyncExit`, `fiber:await()`, `eff:exit()`, `onExit` finalizers and scope finalizers.

#### Fx.Exit.succeed(value)

```lua
Fx.Exit.succeed(value: A) -> Exit<A>
```

```lua
print(Fx.Exit.succeed(5).value) --> 5
```

#### Fx.Exit.failCause(cause)

```lua
Fx.Exit.failCause(cause: Cause) -> Exit<never>
```

```lua
print(Fx.Exit.failCause(Fx.Cause.fail('x'))._tag) --> Failure
```

#### Fx.Exit.isSuccess(exit) and Fx.Exit.isFailure(exit)

```lua
Fx.Exit.isSuccess(exit: Exit) -> boolean
Fx.Exit.isFailure(exit: Exit) -> boolean
```

```lua
local exit = Fx.runSyncExit(Fx.succeed(1))
print(Fx.Exit.isSuccess(exit), Fx.Exit.isFailure(exit)) --> true false
```

#### Fx.Exit.unit

```lua
Fx.Exit.unit: Exit<nil> -- { _tag = 'Success', value = nil }
```

- **Notes:** the exit passed to scope finalizers when a scope is closed without one.

```lua
print(Fx.Exit.unit._tag) --> Success
```

### Errors across boundaries

#### Fx.serializeError(err)

```lua
Fx.serializeError(err: table) -> table
```

- **Parameters:** `err`, a tagged error (or any table).
- **Returns:** a plain copy without a metatable or the `_fxTagged` marker. Functions, threads and userdata are dropped, and tables nested deeper than 8 levels are cut off.
- **Notes:** use it before sending an error through `TriggerClientEvent`, KVP or JSON. `Fx.rpc` already does this.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local wire = Fx.serializeError(NotEnoughMoney { need = 50, onRetry = function() end })
print(wire._tag, wire.need, wire.onRetry, getmetatable(wire)) --> NotEnoughMoney 50 nil nil
```

#### Fx.taggedFromTable(t)

```lua
Fx.taggedFromTable(t: table) -> TaggedError
```

- **Parameters:** `t`, a plain table with a `_tag`, for example one received from the network.
- **Returns:** a copy that behaves as a tagged error: it has `:fail()`, matches `catchTag` and the class's `.is`, and raising it inside effect code is a failure.
- **Notes:** its `tostring` is always the inspect rendering (it does not use `message`).

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local received = { _tag = 'NotEnoughMoney', need = 50 }
local e = Fx.taggedFromTable(received)
local handled = e:fail():catchTag('NotEnoughMoney', function(err) return Fx.succeed(err.need) end)
print(Fx.runSync(handled), NotEnoughMoney.is(e)) --> 50 true
```

#### Fx.inspect(value)

```lua
Fx.inspect(value: any) -> string
```

- **Returns:** a one-line rendering for logs. Strings are quoted, table keys are sorted, nesting deeper than 3 levels shows `{...}`, and a table with a `_tag` is prefixed with the tag (`_tag` and `_fxTagged` are not listed as fields).

```lua
print(Fx.inspect({ plate = 'ABC', seats = { 1, 2 } })) --> { plate = "ABC", seats = { [1] = 1, [2] = 2 } }
```

### Built-in core error tags

| Class | `_tag` | Raised by | Fields |
|---|---|---|---|
| `Fx.TimeoutError` | `'TimeoutError'` | `eff:timeout(ms)` | `timeoutMs` |
| `Fx.NoSuchElementError` | `'NoSuchElementError'` | `Fx.fromNullable(nil)` without `onNil` | none |
| `Fx.UnknownError` | `'UnknownError'` | `Fx.try` without `onError` | `message` (`tostring` of the raised error), `cause` (the raised value) |
| `Fx.ParseError` | `'ParseError'` | `schema:decode(input)`, `schema:parse(input)` ([Schema](#schema)) | `message` (the schema message, for example `amount: expected integer, got "x"`) |

The FiveM modules declare their own tags (`RpcTimeout`, `AssetTimeout`, `SqlError`, `InsufficientFunds`, ...); see the [Errors catalogue](#errors-and-gotchas).

```lua
local exit = Fx.runSyncExit(Fx.try(function() error('lost connection', 0) end))
local e = Fx.Cause.failureOption(exit.cause)
print(e._tag, e.message, Fx.UnknownError.is(e)) --> UnknownError lost connection true
```

#### What runSync and runAwait raise

`Fx.runSync` and `Fx.runAwait` (and `Runtime:runAwait`) turn a failed exit into a Lua error raised with `error(value, 0)`:

- an expected failure (and no defects): the error value itself, so `pcall` returns your tagged error table;
- a defect: the defect value; a string defect with a traceback gets the traceback appended after a newline;
- interruption only: the table `{ _tag = 'Interrupted', _fxCause = cause }`. It is not a tagged error. Raised again inside effect code, it fails with the original cause.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local ok, err = pcall(Fx.runSync, NotEnoughMoney { need = 5 }:fail())
print(ok, err._tag, err.need) --> false NotEnoughMoney 5
local ok2, err2 = pcall(Fx.runSync, Fx.failCause(Fx.Cause.interrupt(1)))
print(ok2, err2._tag) --> false Interrupted
```

<a id="concurrency"></a>

## Concurrency
This page covers fibers (fork, join, interrupt), running many effects at once with `Fx.forEach`, `Fx.all` and races, uninterruptible regions, and the shared-state tools: `Ref`, `Deferred`, `Semaphore`, `Queue` and `PubSub`. Use it when work has to run in the background, in parallel, or has to coordinate between fibers. Fibers are cooperative coroutines in one Lua state; "concurrent" means interleaved while fibers wait, never two pieces of Lua running at the same instant. See [How fibers run](#how-fibers-run).

Examples print values with a `--> result` comment showing what they print.

### Fibers

A fiber runs one effect. It has a numeric `id` and, once finished, an `exit` field holding its [Exit](#fxexit) (`nil` while running). Fibers start on the next pass of the runner, not at the moment you fork them.

How fibers are tied together:

| Started with | Parent | Interrupted when | Unhandled failure logged |
|---|---|---|---|
| `eff:fork()` | the forking fiber | the parent finishes (for any reason), or resource stop through the parent | no; join it or handle errors inside it |
| `eff:forkDaemon()` | none (root fiber) | resource stop, or you interrupt it | yes |
| `eff:forkScoped()` | none (root fiber) | the current `Scope` closes, or resource stop | yes |
| `Fx.runFork(eff)` | none (root fiber) | resource stop, or you interrupt it | yes, unless `onExit` is given |

#### eff:fork()

```lua
eff:fork() -> Effect<Fiber, never>
```

- **Returns:** an effect that starts `eff` on a child fiber and succeeds with the fiber right away.
- **Notes:** the child sees the parent's services. It is interrupted when the parent finishes, so a fork that must outlive the current effect needs `forkDaemon` or `forkScoped`. Failures of a child are not logged; observe them with `join` or `await`.

```lua
local eff = Fx.gen(function()
  local fiber = Fx.yield(Fx.succeed('vehicle spawned'):delay(200):fork())
  print('forked, waiting')
  return Fx.yield(fiber:join())
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end })
--> forked, waiting
--> vehicle spawned
```

#### eff:forkDaemon()

```lua
eff:forkDaemon() -> Effect<Fiber, never>
```

- **Returns:** an effect that starts `eff` on a root fiber that outlives the effect that forked it.
- **Notes:** it inherits the forking fiber's services. It is interrupted on resource stop. An unhandled failure is logged, like `Fx.runFork` without `onExit`.

```lua
local done = false
local handler = Fx.sync(function() done = true end):delay(1000):forkDaemon():asVoid()
Fx.runFork(handler, { onExit = function() print('handler returned', done) end })
Fx.runFork(Fx.sleep(2000):zipRight(Fx.sync(function() print('daemon finished', done) end)))
--> handler returned false
--> daemon finished true
```

#### eff:forkScoped()

```lua
eff:forkScoped() -> Effect<Fiber, never>  -- requires Scope
```

- **Returns:** an effect that starts `eff` as a daemon fiber and interrupts it when the current [Scope](#scope) closes.
- **Fails with:** a defect `Service not found: Scope` when no scope is provided. Wrap the code in `Fx.scoped` or use it inside `Layer.scoped`.

```lua
local heartbeat = Fx.sync(function() print('beat') end):delay(400):forever()
local session = Fx.scoped(Fx.gen(function()
  Fx.yield(heartbeat:forkScoped())
  Fx.yield(Fx.sleep(1000)) -- the session lasts one second
end))
Fx.runFork(session, { onExit = function() print('session closed') end })
--> beat
--> beat
--> session closed
```

#### fiber:join()

```lua
fiber:join() -> Effect<A, E>
```

- **Returns:** an effect that waits for the fiber and succeeds with its value.
- **Fails with:** the fiber's cause, as is. Joining an interrupted fiber fails with its interruption cause, which `catchAllCause` can handle (it is not the joiner's own interruption).

```lua
local eff = Fx.gen(function()
  local f = Fx.yield(Fx.fail('engine stalled'):delay(10):fork())
  return Fx.yield(f:join():catchAll(function(e) return Fx.succeed('caught: ' .. e) end))
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> caught: engine stalled
```

#### fiber:await()

```lua
fiber:await() -> Effect<Exit<A>, never>
```

- **Returns:** an effect that waits for the fiber and succeeds with its [Exit](#fxexit). It never fails.

```lua
local eff = Fx.gen(function()
  local f = Fx.yield(Fx.fail('no fuel'):fork())
  local exit = Fx.yield(f:await())
  return exit._tag
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> Failure
```

#### fiber:interrupt()

```lua
fiber:interrupt() -> Effect<Exit<A>, never>
```

- **Returns:** an effect that interrupts the fiber, waits until it has stopped (finalizers included) and succeeds with its exit.
- **Notes:** a fiber in an uninterruptible region finishes that region first. If the fiber already finished, it just returns the exit. The interruption cause carries the interrupting fiber's id.

```lua
local eff = Fx.gen(function()
  local f = Fx.yield(Fx.never:ensuring(Fx.sync(function() print('blip removed') end)):fork())
  Fx.yield(Fx.sleep(100))
  local exit = Fx.yield(f:interrupt())
  return Fx.Cause.isInterruptedOnly(exit.cause)
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end })
--> blip removed
--> true
```

#### fiber:interruptAsFork(byId?)

```lua
fiber:interruptAsFork(byId?: integer) -> nil
```

- **Parameters:** `byId`, the id stored in the interruption cause.
- **Notes:** plain function, not an effect. Requests interruption and returns at once without waiting. Calling it again, or on a finished fiber, does nothing. Use it from plain Lua code (an event handler, a command) to stop a fiber started with `Fx.runFork`.

```lua
local loop = Fx.runFork(Fx.sync(function() end):delay(100):forever(), {
  onExit = function(exit) print('stopped', Fx.Cause.isInterruptedOnly(exit.cause)) end,
})
Fx.runFork(Fx.sleep(250):zipRight(Fx.sync(function() loop:interruptAsFork() end)))
--> stopped true
```

#### fiber:addObserver(cb)

```lua
fiber:addObserver(cb: fun(exit: Exit<A>)) -> fun()
```

- **Returns:** a function that removes the observer.
- **Notes:** plain Lua callback, called once when the fiber ends. Errors raised in `cb` at that point are reported, not raised. If the fiber has already ended, `cb` is called right away and its errors propagate to the caller.

```lua
local f = Fx.runFork(Fx.succeed(7):delay(50), { onExit = function() end })
f:addObserver(function(exit) print('done with', exit.value) end) --> done with 7
```

#### Fx.interruptAll(fibers)

```lua
Fx.interruptAll(fibers: Fiber[]) -> Effect<nil, never>
```

- **Returns:** an effect that interrupts every fiber in the list and waits until all have stopped.

```lua
local eff = Fx.gen(function()
  local a = Fx.yield(Fx.never:fork())
  local b = Fx.yield(Fx.never:fork())
  Fx.yield(Fx.interruptAll({ a, b }))
  return a.exit ~= nil and b.exit ~= nil
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> true
```

### Running many effects

#### Fx.forEach(items, f, opts?)

```lua
Fx.forEach(items: T[], f: fun(item: T, i: integer): Effect<B, E>, opts?: { concurrency?: integer | 'unbounded', discard?: boolean }) -> Effect<B[], E>
```

- **Parameters:** `items`, a sequence (`#items` is used). `f`, called with each item and its index; must return an effect. `opts.concurrency`, how many run at once: a number or `'unbounded'` (all at once). Default `1` (one after another). `opts.discard`, do not collect results.
- **Returns:** an effect that succeeds with the results in input order, whatever order they finished in.
- **Fails with:** the first failure. In sequential mode the remaining items do not run. In concurrent mode the other running workers are interrupted, and the effect waits for them to stop before failing.
- **Notes:**
  - With `concurrency > 1`, the items run on child fibers (at most `concurrency` workers, each taking the next item when done), so interrupting the caller interrupts them all.
  - With `discard = true`, results are not kept and the effect succeeds with an empty table.
  - A return value of `f` that is not an effect is a defect.

```lua
local function refuel(plate) return Fx.succeed(plate .. ' full'):delay(100) end
local eff = Fx.forEach({ 'AAA111', 'BBB222', 'CCC333', 'DDD444' }, refuel, { concurrency = 2 })
Fx.runFork(eff, { onExit = function(exit) print(table.concat(exit.value, ', ')) end })
--> AAA111 full, BBB222 full, CCC333 full, DDD444 full
```

#### Fx.all(effects, opts?)

```lua
Fx.all(effects: Effect[] | table<string, Effect>, opts?: { concurrency?: integer | 'unbounded' }) -> Effect<table, E>
```

- **Parameters:** `effects`, a list or a record of effects. `opts.concurrency`, as for `forEach` (default `1`).
- **Returns:** an effect that succeeds with results of the same shape: a list in order, or a table with the same keys.
- **Fails with:** the first failure, as `forEach`.
- **Notes:** a table counts as a list when `#effects > 0` or it is empty. Records run in `pairs` order, which is not defined; use `concurrency` or a list when order matters.

```lua
local profile = Fx.all({
  name = Fx.succeed('Ana'):delay(50),
  cash = Fx.succeed(1200):delay(80),
  job = Fx.succeed('mechanic'):delay(30),
}, { concurrency = 'unbounded' })
Fx.runFork(profile, { onExit = function(exit) print(exit.value.name, exit.value.cash, exit.value.job) end })
--> Ana 1200 mechanic
```

#### eff:race(that)

```lua
eff:race(that: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** an effect that runs both on child fibers and succeeds with the first **success**. The loser is interrupted and awaited.
- **Fails with:** only when both fail: a `Parallel` cause holding both causes (in the order they finished).

```lua
local fromCache = Fx.fail('cache miss')
local fromDb = Fx.succeed({ plate = 'ABC123' }):delay(120)
Fx.runFork(fromCache:race(fromDb), { onExit = function(exit) print(exit.value.plate) end }) --> ABC123
```

#### eff:raceFirst(that)

```lua
eff:raceFirst(that: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** an effect whose result is that of whichever side **finishes** first, success or failure. The other side is interrupted.

```lua
local eff = Fx.fail('player dropped'):delay(10):raceFirst(Fx.succeed('trade done'):delay(50))
Fx.runFork(eff, { onExit = function(exit) print(Fx.Cause.failureOption(exit.cause)) end }) --> player dropped
```

#### Fx.raceAll(effects)

```lua
Fx.raceAll(effects: Effect<A, E>[]) -> Effect<A, E>
```

- **Returns:** the first success among all effects; the rest are interrupted.
- **Fails with:** a `Parallel` cause of all failures when every effect fails.

```lua
local servers = {
  Fx.fail('eu down'),
  Fx.succeed('us-east'):delay(200),
  Fx.succeed('us-west'):delay(90),
}
Fx.runFork(Fx.raceAll(servers), { onExit = function(exit) print(exit.value) end }) --> us-west
```

### Interruption

Interruption is how fibers are stopped: `fiber:interrupt()`, a timeout, a race loser, a parent finishing, a scope closing, resource stop. An interrupted fiber stops at its next step (at once if it is waiting on `Fx.sleep`, `Fx.async`, a `Queue` or a `Deferred`), runs its finalizers, and ends with an `Interrupt` cause. Recovery handlers do not run during interruption (see [Errors](#failures-defects-and-interruptions)).

#### eff:uninterruptible()

```lua
eff:uninterruptible() -> Effect<A, E>
```

- **Returns:** `eff` running in an uninterruptible region. An interruption requested meanwhile waits; it lands as soon as the region ends, so code after the region does not run.
- **Notes:** keep regions short. A `timeout` around an uninterruptible effect waits for it before failing. `Fx.acquireRelease` acquisitions and scope closing are already uninterruptible.

```lua
local saved = false
local save = Fx.sleep(300):zipRight(Fx.sync(function() saved = true end)):uninterruptible()
local eff = Fx.gen(function()
  local f = Fx.yield(save:fork())
  Fx.yield(Fx.sleep(10))
  local exit = Fx.yield(f:interrupt()) -- waits for the save to finish
  return exit._tag
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value, saved) end }) --> Failure true
```

#### eff:interruptible()

```lua
eff:interruptible() -> Effect<A, E>
```

- **Returns:** `eff` running interruptibly, even inside an uninterruptible region.

```lua
local eff = Fx.gen(function()
  local f = Fx.yield(Fx.never:interruptible():uninterruptible():fork())
  Fx.yield(Fx.sleep(10))
  return Fx.yield(f:interrupt())._tag
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> Failure
```

#### Fx.uninterruptibleMask(f)

```lua
Fx.uninterruptibleMask(f: fun(restore: fun(eff: Effect): Effect): Effect<A, E>) -> Effect<A, E>
```

- **Parameters:** `f`, builds the effect. It runs uninterruptibly; `restore(eff)` runs `eff` with the interruptibility from outside the mask.
- **Notes:** the building block of `acquireUseRelease`: acquire and release are protected, the use part stays interruptible.

```lua
local eff = Fx.uninterruptibleMask(function(restore)
  return Fx.sync(function() print('lock taken') end)
    :zipRight(restore(Fx.sleep(1000)))
    :ensuring(Fx.sync(function() print('lock released') end))
end)
Fx.runFork(eff:timeoutOption(100), { onExit = function(exit) print('result', exit.value) end })
--> lock taken
--> lock released
--> result nil
```

### Ref

A mutable cell shared by fibers. Every operation is an effect and runs without interleaving, so `update` and `modify` are atomic with respect to other fibers.

#### Fx.Ref.make(value) and Fx.Ref.unsafeMake(value)

```lua
Fx.Ref.make(value: A) -> Effect<Ref<A>, never>
Fx.Ref.unsafeMake(value: A) -> Ref<A>
```

- **Returns:** a new ref. `unsafeMake` builds it immediately, outside any effect (for module-level state).

```lua
local onlineCount = Fx.Ref.unsafeMake(0)
print(Fx.runSync(onlineCount:get())) --> 0
```

#### ref:get(), ref:set(value)

```lua
ref:get() -> Effect<A, never>
ref:set(value: A) -> Effect<nil, never>
```

```lua
local eff = Fx.gen(function()
  local weather = Fx.yield(Fx.Ref.make('CLEAR'))
  Fx.yield(weather:set('RAIN'))
  return Fx.yield(weather:get())
end)
print(Fx.runSync(eff)) --> RAIN
```

#### ref:update(f), ref:updateAndGet(f), ref:getAndSet(value)

```lua
ref:update(f: fun(old: A): A) -> Effect<nil, never>
ref:updateAndGet(f: fun(old: A): A) -> Effect<A, never>
ref:getAndSet(value: A) -> Effect<A, never>   -- succeeds with the old value
```

```lua
local eff = Fx.gen(function()
  local cash = Fx.yield(Fx.Ref.make(100))
  Fx.yield(cash:update(function(n) return n + 50 end))
  local now = Fx.yield(cash:updateAndGet(function(n) return n * 2 end))
  local old = Fx.yield(cash:getAndSet(0))
  return { now = now, old = old, after = Fx.yield(cash:get()) }
end)
local r = Fx.runSync(eff)
print(r.now, r.old, r.after) --> 300 300 0
```

#### ref:modify(f)

```lua
ref:modify(f: fun(old: A): (R, A)) -> Effect<R, never>
```

- **Parameters:** `f` returns two values: the result, then the new value.
- **Returns:** an effect that stores the new value and succeeds with the result.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local wallet = Fx.Ref.unsafeMake(80)
local function pay(amount)
  return wallet:modify(function(have)
    if have < amount then return false, have end
    return true, have - amount
  end):flatMap(function(paid)
    if not paid then return NotEnoughMoney { need = amount }:fail() end
    return Fx.unit
  end)
end
print(Fx.runSyncExit(pay(50))._tag, Fx.runSyncExit(pay(50))._tag, Fx.runSync(wallet:get())) --> Success Failure 30
```

### Deferred

A value set once and awaited by any number of fibers.

#### Fx.Deferred.make() and Fx.Deferred.unsafeMake()

```lua
Fx.Deferred.make() -> Effect<Deferred<A, E>, never>
Fx.Deferred.unsafeMake() -> Deferred<A, E>
```

```lua
local d = Fx.Deferred.unsafeMake()
print(d:isDone()) --> false
```

#### deferred:await()

```lua
deferred:await() -> Effect<A, E>
```

- **Returns:** an effect that waits until the deferred is completed and succeeds with its value.
- **Fails with:** the error it was failed with.
- **Notes:** returns at once when already completed. An interrupted waiter is removed.

```lua
local eff = Fx.gen(function()
  local loaded = Fx.yield(Fx.Deferred.make())
  Fx.yield(loaded:succeed({ name = 'Ana' }):delay(300):fork())
  local char = Fx.yield(loaded:await())
  return char.name
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> Ana
```

#### deferred:succeed(value), deferred:fail(err), deferred:done(exit)

```lua
deferred:succeed(value: A) -> Effect<boolean, never>
deferred:fail(err: E) -> Effect<boolean, never>
deferred:done(exit: Exit<A>) -> Effect<boolean, never>
deferred:unsafeDone(exit: Exit<A>) -> boolean
```

- **Returns:** `true` when this call completed the deferred, `false` when it was already completed (the first value wins).
- **Notes:** `unsafeDone` is the plain-function form for callbacks.

```lua
local d = Fx.Deferred.unsafeMake()
print(Fx.runSync(d:succeed('first')), Fx.runSync(d:succeed('second'))) --> true false
```

#### deferred:isDone()

```lua
deferred:isDone() -> boolean
```

- **Notes:** plain function, not an effect.

```lua
local d = Fx.Deferred.unsafeMake()
d:unsafeDone(Fx.Exit.succeed(1))
print(d:isDone()) --> true
```

### Semaphore

Limits how many fibers run a section at once. Waiters are served in order (FIFO): a request waits while anyone is queued ahead of it, even if enough permits are free.

#### Fx.Semaphore.make(permits) and Fx.Semaphore.unsafeMake(permits)

```lua
Fx.Semaphore.make(permits: integer) -> Effect<Semaphore, never>
Fx.Semaphore.unsafeMake(permits: integer) -> Semaphore
```

```lua
local garageSlots = Fx.Semaphore.unsafeMake(2)
print(garageSlots.permits) --> 2
```

#### semaphore:withPermit(eff) and semaphore:withPermits(n, eff)

```lua
semaphore:withPermit(eff: Effect<A, E>) -> Effect<A, E>
semaphore:withPermits(n: integer, eff: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** `eff`, run while holding 1 (or `n`) permits. The permits are released however `eff` ends, including interruption.
- **Notes:** asking for more permits than the semaphore has waits forever.

```lua
local dbSlots = Fx.Semaphore.unsafeMake(1)
local active, peak = 0, 0
local function saveCharacter(src)
  return dbSlots:withPermit(Fx.sync(function() active = active + 1; peak = math.max(peak, active) end)
    :zipRight(Fx.sleep(50))
    :zipRight(Fx.sync(function() active = active - 1 end)))
end
Fx.runFork(Fx.forEach({ 1, 2, 3 }, saveCharacter, { concurrency = 'unbounded' }), {
  onExit = function() print('peak', peak) end,
})
--> peak 1
```

#### semaphore:take(n?) and semaphore:release(n?)

```lua
semaphore:take(n?: integer) -> Effect<nil, never>     -- default 1
semaphore:release(n?: integer) -> Effect<nil, never>  -- default 1
semaphore:unsafeRelease(n?: integer) -> nil
```

- **Notes:** manual control. Prefer `withPermit`, which cannot leak permits. `take` waits until the permits are free; an interrupted `take` leaves the queue.

```lua
local sem = Fx.Semaphore.unsafeMake(1)
local eff = sem:take():zipRight(Fx.sync(function() print('in', sem.permits) end)):zipRight(sem:release())
Fx.runFork(eff, { onExit = function() print('out', sem.permits) end })
--> in 0
--> out 1
```

### Queue

A FIFO between fibers. `take` waits while the queue is empty. What `offer` does on a full queue depends on the strategy:

| Constructor | Capacity | `offer` when full |
|---|---|---|
| `Fx.Queue.unbounded()` | unlimited | never full |
| `Fx.Queue.bounded(n)` | `n` | waits for room (strategy `'suspend'`) |
| `Fx.Queue.dropping(n)` | `n` | drops the new item, succeeds with `false` |
| `Fx.Queue.sliding(n)` | `n` | drops the oldest item, adds the new one, succeeds with `true` |

#### Fx.Queue.unbounded(), bounded(n), dropping(n), sliding(n)

```lua
Fx.Queue.unbounded() -> Effect<Queue, never>
Fx.Queue.bounded(n: integer) -> Effect<Queue, never>
Fx.Queue.dropping(n: integer) -> Effect<Queue, never>
Fx.Queue.sliding(n: integer) -> Effect<Queue, never>
```

```lua
local eff = Fx.gen(function()
  local chat = Fx.yield(Fx.Queue.sliding(2))
  for _, msg in ipairs({ 'hi', 'anyone?', 'hello' }) do Fx.yield(chat:offer(msg)) end
  return Fx.yield(chat:takeAll())
end)
Fx.runFork(eff, { onExit = function(exit) print(table.concat(exit.value, ' | ')) end }) --> anyone? | hello
```

#### Fx.Queue.unsafeMake(capacity?, strategy?) and Fx.Queue.unsafeUnbounded()

```lua
Fx.Queue.unsafeMake(capacity?: integer, strategy?: 'suspend' | 'dropping' | 'sliding') -> Queue
Fx.Queue.unsafeUnbounded() -> Queue
```

- **Notes:** build a queue immediately, outside any effect. Defaults: unbounded, `'suspend'`.

```lua
local jobs = Fx.Queue.unsafeMake(10, 'dropping')
print(jobs.capacity, jobs.strategy) --> 10 dropping
```

#### queue:offer(value)

```lua
queue:offer(value: any) -> Effect<boolean, never>
```

- **Returns:** `true` when the value was added (or handed straight to a waiting taker); `false` when a dropping queue was full.
- **Notes:** on a full bounded queue it waits for room, then succeeds with `true`. An interrupted waiting offer is withdrawn. `offer` is an async effect even when there is room, so it cannot run under `Fx.runSync`; use `unsafeOffer` from plain code. Do not offer `nil`: a `nil` item is indistinguishable from "empty" for `poll`.

```lua
local eff = Fx.gen(function()
  local q = Fx.yield(Fx.Queue.dropping(1))
  return { Fx.yield(q:offer('job1')), Fx.yield(q:offer('job2')) }
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value[1], exit.value[2]) end }) --> true false
```

#### queue:take()

```lua
queue:take() -> Effect<any, never>
```

- **Returns:** an effect that waits for an item and succeeds with it. Waiting takers are served in order.

```lua
local eff = Fx.gen(function()
  local deliveries = Fx.yield(Fx.Queue.unbounded())
  Fx.yield(deliveries:offer('pizza'):delay(500):fork())
  return Fx.yield(deliveries:take())
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> pizza
```

#### queue:poll(), queue:takeAll(), queue:size()

```lua
queue:poll() -> Effect<any | nil, never>   -- nil when empty
queue:takeAll() -> Effect<any[], never>    -- everything queued now
queue:size() -> Effect<integer, never>
```

- **Notes:** none of these wait.

```lua
local eff = Fx.gen(function()
  local q = Fx.yield(Fx.Queue.unbounded())
  Fx.yield(q:offer('a'))
  Fx.yield(q:offer('b'))
  local first = Fx.yield(q:poll())
  return { first = first, left = Fx.yield(q:size()), none = Fx.yield(Fx.Queue.unsafeUnbounded():poll()) }
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value.first, exit.value.left, exit.value.none) end }) --> a 1 nil
```

#### queue:unsafeOffer(value), queue:unsafePoll(), queue:unsafeSize()

```lua
queue:unsafeOffer(value: any) -> boolean
queue:unsafePoll() -> any | nil
queue:unsafeSize() -> integer
```

- **Notes:** plain functions for callbacks (event handlers, `AddEventHandler`). `unsafeOffer` never waits: it returns `false` when a bounded or dropping queue is full; a sliding queue drops its oldest item.

```lua
local events = Fx.Queue.unsafeMake(1)
print(events:unsafeOffer('enter'), events:unsafeOffer('exit'), events:unsafePoll()) --> true false enter
```

### PubSub

Broadcasts each message to every subscriber that subscribed before it was published.

#### Fx.PubSub.make() and Fx.PubSub.unsafeMake()

```lua
Fx.PubSub.make() -> Effect<PubSub, never>
Fx.PubSub.unsafeMake() -> PubSub
```

```lua
local weatherChanged = Fx.PubSub.unsafeMake()
print(type(weatherChanged.subscribe)) --> function
```

#### pubsub:publish(value) and pubsub:unsafePublish(value)

```lua
pubsub:publish(value: any) -> Effect<nil, never>
pubsub:unsafePublish(value: any) -> nil
```

- **Notes:** publishing never waits. Each subscriber queue gets the value (or drops by its strategy), then each `on` listener is called. A listener that raises is reported and does not stop the others.

```lua
local ps = Fx.PubSub.unsafeMake()
ps:on(function(v) print('listener got', v) end)
Fx.runSync(ps:publish('RAIN')) --> listener got RAIN
```

#### pubsub:subscribe(opts?)

```lua
pubsub:subscribe(opts?: { buffer?: integer, strategy?: 'sliding' | 'dropping' }) -> Effect<Queue, never>  -- requires Scope
```

- **Parameters:** `opts.buffer`, capacity of the subscriber's queue (default unlimited). `opts.strategy`, what to drop when it is full: `'sliding'` (default, drops the oldest) or `'dropping'` (drops the newest).
- **Returns:** a [Queue](#queue) that receives every message published from now until the scope closes.
- **Fails with:** a defect `Service not found: Scope` outside a scope.

```lua
local alerts = Fx.PubSub.unsafeMake()
local listen = Fx.scoped(Fx.gen(function()
  local inbox = Fx.yield(alerts:subscribe({ buffer = 10 }))
  return Fx.yield(inbox:take())
end))
Fx.runFork(listen, { onExit = function(exit) print('dispatch:', exit.value) end })
Fx.runFork(alerts:publish('10-50 at Legion Square'):delay(100))
--> dispatch: 10-50 at Legion Square
```

#### pubsub:on(fn)

```lua
pubsub:on(fn: fun(value: any)) -> fun()
```

- **Returns:** a function that removes the listener.
- **Notes:** a plain callback, called synchronously from `publish`. Use it to bridge into non-effect code.

```lua
local ps = Fx.PubSub.unsafeMake()
local seen = {}
local off = ps:on(function(v) seen[#seen + 1] = v end)
ps:unsafePublish(1)
off()
ps:unsafePublish(2)
print(#seen) --> 1
```

For a stream of published values (`Fx.Stream.fromPubSub`), see [Streams](#streams).

<a id="scopes-services-layers"></a>

## Scopes, services and Layers
This page covers resource safety (scopes, finalizers, `acquireRelease`, resource-stop cleanup) and dependency injection (service tags, Layers, Runtimes). Use scopes for anything that must be undone: spawned entities, loaded models, focus, event handlers, background loops. Use tags and layers to give handlers their dependencies (a bank, a database, a framework adapter) without globals, and to swap them in tests.

Examples print values with a `--> result` comment showing what they print.

### Finalizers on one effect

These run a finalizer after an effect however it ends. Finalizers run uninterruptibly. Every callback must return an effect (`Fx.unit` when there is nothing to do); returning `nil` is a defect.

If a finalizer fails: when the effect had succeeded, the whole effect fails with the finalizer's cause; when the effect had failed, the cause becomes `Sequential(original, finalizer cause)`, which the expected-error handlers do not catch (it contains a defect or a second failure).

#### eff:ensuring(finalizer)

```lua
eff:ensuring(finalizer: Effect<any, any>) -> Effect<A, E>
```

- **Parameters:** `finalizer`, an effect run after `eff` on success, failure and interruption.
- **Returns:** an effect with the result of `eff`.

```lua
local frozen = true
local cutscene = Fx.sleep(5000):ensuring(Fx.sync(function() frozen = false end))
Fx.runFork(cutscene:timeoutOption(1000), { onExit = function() print('player frozen:', frozen) end })
--> player frozen: false
```

#### eff:onExit(fin)

```lua
eff:onExit(fin: fun(exit: Exit<A>): Effect<any, any>) -> Effect<A, E>
```

- **Parameters:** `fin`, called with the [Exit](#fxexit) of `eff`; must return an effect.
- **Returns:** an effect with the result of `eff`.

```lua
local function logged(name, eff)
  return eff:onExit(function(exit)
    print(name, exit._tag)
    return Fx.unit
  end)
end
Fx.runSync(logged('payday', Fx.succeed(500)))
Fx.runSyncExit(logged('rob bank', Fx.fail('police nearby')))
--> payday Success
--> rob bank Failure
```

#### eff:onError(f)

```lua
eff:onError(f: fun(cause: Cause): Effect<any, any>) -> Effect<A, E>
```

- **Parameters:** `f`, called with the cause when `eff` does not succeed (failure, defect or interruption); must return an effect.
- **Notes:** it observes, it does not recover. The effect still fails.

```lua
local eff = Fx.fail('vehicle not found'):onError(function(cause)
  print('refunding, reason:', Fx.Cause.squash(cause))
  return Fx.unit
end)
print(Fx.runSyncExit(eff)._tag)
--> refunding, reason: vehicle not found
--> Failure
```

#### eff:onInterrupt(f)

```lua
eff:onInterrupt(f: fun(): Effect<any, any>) -> Effect<A, E>
```

- **Parameters:** `f`, called with no arguments when `eff` ends with a cause that contains an interruption; must return an effect.

```lua
local search = Fx.never:onInterrupt(function()
  return Fx.sync(function() print('search cancelled, removing blips') end)
end)
Fx.runFork(search:timeoutOption(2000))
--> search cancelled, removing blips
```

#### Fx.acquireUseRelease(acquire, use, release)

```lua
Fx.acquireUseRelease(acquire: Effect<A, E1>, use: fun(a: A): Effect<B, E2>, release: fun(a: A, exit: Exit<B>): Effect<any, any>) -> Effect<B, E1 | E2>
```

- **Parameters:** `acquire`, gets the resource (runs uninterruptibly). `use`, uses it; must return an effect (interruptible). `release`, frees it with the exit of `use`; must return an effect (runs uninterruptibly).
- **Returns:** the result of `use`.
- **Fails with:** the errors of `acquire` (then nothing is released) or of `use`.
- **Notes:** no scope needed. Use it when the resource lives only for one block of code; use `Fx.acquireRelease` when its lifetime is a scope.

```lua
local function withLockedVehicle(plate, use)
  return Fx.acquireUseRelease(
    Fx.sync(function() print('lock', plate) return plate end),
    use,
    function(p, exit) return Fx.sync(function() print('unlock', p, exit._tag) end) end)
end
Fx.runSyncExit(withLockedVehicle('ABC123', function(p) return Fx.fail('no fuel') end))
--> lock ABC123
--> unlock ABC123 Failure
```

### Scope

A scope collects finalizers and runs them, last added first, when it closes. `Fx.Scope` is both the scope module and the [service tag](#services) of the current scope: `Fx.yield(Fx.Scope)` returns the scope your code runs in. Every open scope also closes when the resource stops.

#### Fx.scoped(eff)

```lua
Fx.scoped(eff: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** `eff`, run with a fresh scope as its `Scope` service. The scope closes when `eff` ends, with `eff`'s exit, and its finalizers run before `Fx.scoped` returns.
- **Notes:** the usual way to give a block of code its own lifetime.

```lua
local function useVehicle(plate)
  return Fx.acquireRelease(
    Fx.sync(function() print('spawn', plate) return plate end),
    function(p) return Fx.sync(function() print('delete', p) end) end)
end
local testDrive = Fx.scoped(Fx.gen(function()
  local car = Fx.yield(useVehicle('TEST01'))
  print('driving', car)
end))
Fx.runSync(testDrive)
--> spawn TEST01
--> driving TEST01
--> delete TEST01
```

#### Fx.acquireRelease(acquire, release)

```lua
Fx.acquireRelease(acquire: Effect<A, E>, release: fun(a: A, exit: Exit): Effect<any, any>) -> Effect<A, E>  -- requires Scope
```

- **Parameters:** `acquire`, gets the resource. `release`, called with the resource and the scope's closing exit; must return an effect.
- **Returns:** an effect that acquires the resource, registers `release` on the current scope, and succeeds with the resource.
- **Fails with:** the errors of `acquire` (then nothing is registered). A defect `Service not found: Scope` without a scope.
- **Notes:** acquire and registration run uninterruptibly, so a resource is never acquired without its release. Resources in one scope are released in reverse order of acquisition.

```lua
local log = {}
local function res(name)
  return Fx.acquireRelease(Fx.sync(function() log[#log + 1] = '+' .. name return name end),
    function(n, exit) return Fx.sync(function() log[#log + 1] = '-' .. n .. ':' .. exit._tag end) end)
end
Fx.runSyncExit(Fx.scoped(Fx.gen(function()
  Fx.yield(res('model'))
  Fx.yield(res('vehicle'))
  Fx.yield(Fx.fail('driver left'))
end)))
print(table.concat(log, ' ')) --> +model +vehicle -vehicle:Failure -model:Failure
```

#### Fx.addFinalizer(fin)

```lua
Fx.addFinalizer(fin: fun(exit: Exit): Effect<any, any>) -> Effect<nil, never>  -- requires Scope
```

- **Parameters:** `fin`, called with the scope's closing exit; must return an effect.
- **Fails with:** a defect `Service not found: Scope` without a scope.

```lua
local eff = Fx.scoped(Fx.gen(function()
  Fx.yield(Fx.addFinalizer(function(exit) return Fx.sync(function() print('hud hidden', exit._tag) end) end))
  print('hud shown')
end))
Fx.runSync(eff)
--> hud shown
--> hud hidden Success
```

#### Fx.Scope.make() and Fx.Scope.unsafeMake()

```lua
Fx.Scope.make() -> Effect<ScopeObject, never>
Fx.Scope.unsafeMake() -> ScopeObject
```

- **Returns:** a new open scope. You close it yourself (or resource stop does).
- **Notes:** a scope object has fields `id`, `closed` (boolean) and, once closed, `exit`.

```lua
local s = Fx.Scope.unsafeMake()
print(s.closed) --> false
```

#### scope:addFinalizer(fin)

```lua
scope:addFinalizer(fin: fun(exit: Exit): Effect<any, any>) -> Effect<nil, never>
scope:unsafeAddFinalizer(fin: fun(exit: Exit): Effect<any, any>) -> fun()
```

- **Returns:** `unsafeAddFinalizer` returns a function that removes the finalizer again.
- **Notes:** adding a finalizer to a scope that is already closed runs it right away, on a new fiber, with the scope's exit.

```lua
local s = Fx.Scope.unsafeMake()
local remove = s:unsafeAddFinalizer(function() return Fx.sync(function() print('never printed') end) end)
remove()
Fx.runSync(s:addFinalizer(function() return Fx.sync(function() print('closed') end) end))
Fx.runSync(s:close())
--> closed
```

#### scope:close(exit?)

```lua
scope:close(exit?: Exit) -> Effect<nil, never>
```

- **Parameters:** `exit`, passed to every finalizer (default `Fx.Exit.unit`).
- **Notes:** runs the finalizers in reverse order, uninterruptibly. A failing finalizer is reported (`error in scope finalizer`) and does not stop the others. Closing a closed scope does nothing.

```lua
local s = Fx.Scope.unsafeMake()
Fx.runSync(s:addFinalizer(function() return Fx.sync(function() print('first added, runs last') end) end))
Fx.runSync(s:addFinalizer(function() return Fx.sync(function() print('last added, runs first') end) end))
Fx.runSync(s:close())
print(s.closed)
--> last added, runs first
--> first added, runs last
--> true
```

#### scope:closeSync(exit?)

```lua
scope:closeSync(exit?: Exit) -> nil
```

- **Notes:** plain function. Closes the scope right now without waiting. A finalizer that needs to wait (`Fx.sleep`, an RPC, a database call) cannot finish; it is reported (`error in scope finalizer on stop`) and skipped. Resource stop closes scopes this way.

```lua
local s = Fx.Scope.unsafeMake()
Fx.runSync(s:addFinalizer(function() return Fx.sync(function() print('entity deleted') end) end))
s:closeSync()
--> entity deleted
```

#### scope:fork()

```lua
scope:fork() -> ScopeObject
```

- **Returns:** a child scope that closes when the parent closes (with the parent's exit), or earlier on its own.

```lua
local session = Fx.Scope.unsafeMake()
local mission = session:fork()
Fx.runSync(mission:addFinalizer(function() return Fx.sync(function() print('mission cleaned up') end) end))
Fx.runSync(session:close())
print(mission.closed)
--> mission cleaned up
--> true
```

#### scope:extend(eff)

```lua
scope:extend(eff: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** `eff` with this scope as its `Scope` service. Resources it acquires live until this scope closes, not until `eff` ends.

```lua
local playerScope = Fx.Scope.unsafeMake()
local giveRadio = Fx.acquireRelease(Fx.succeed('radio'), function(item)
  return Fx.sync(function() print('removed', item) end)
end)
print(Fx.runSync(playerScope:extend(giveRadio))) -- still held
Fx.runSync(playerScope:close())
--> radio
--> removed radio
```

#### scope:unsafeAttachFiber(fiber)

```lua
scope:unsafeAttachFiber(fiber: Fiber) -> nil
```

- **Notes:** interrupt `fiber` when the scope closes, unless it has already ended. `eff:forkScoped()` does this for you.

```lua
local s = Fx.Scope.unsafeMake()
local f = Fx.runFork(Fx.never, { onExit = function(exit) print('interrupted', Fx.Cause.isInterruptedOnly(exit.cause)) end })
s:unsafeAttachFiber(f)
Fx.runFork(Fx.sleep(10):zipRight(s:close()))
--> interrupted true
```

`eff:forkScoped()` is documented on the [Concurrency](#effforkscoped) page.

### Resource lifecycle

When this resource stops (`onResourceStop` for its own name), Rivo FX:

1. interrupts every root fiber (`Fx.runFork`, `runAwait`, `forkDaemon`, `forkScoped` fibers; children follow their parents), with fiber id `0` in the cause;
2. closes every open scope synchronously with `closeSync`, newest first, with an interruption exit. This includes `Fx.resourceScope`, player scopes and Runtime scopes.

There is no later tick after a resource stops, so finalizers that need to wait are reported and skipped. Keep stop-time cleanup synchronous (`DeleteEntity`, `SetModelAsNoLongerNeeded`, state resets).

#### Fx.onStop(fin)

```lua
Fx.onStop(fin: fun() | Effect<any, any>) -> nil
```

- **Parameters:** `fin`, a plain function (called with no arguments) or an effect.
- **Notes:** plain function, not an effect. Adds `fin` to `Fx.resourceScope`. Several `onStop` callbacks run last registered first. They run with `closeSync`, so `fin` must not wait.

```lua
local blips = { 101, 102 }
Fx.onStop(function()
  for _, b in ipairs(blips) do print('RemoveBlip', b) end
end)
Fx.resourceScope:closeSync() -- what resource stop does
--> RemoveBlip 101
--> RemoveBlip 102
```

#### Fx.resourceScope

```lua
Fx.resourceScope: ScopeObject
```

- **Notes:** a scope that closes when this resource stops. Use `Fx.resourceScope:extend(eff)` for resources that live as long as the resource. For per-player lifetimes see `Fx.player.scope(src)` in [FiveM modules](#players-config-assets-entities).

```lua
local loadModel = Fx.acquireRelease(Fx.succeed('prop_atm_01'), function(m)
  return Fx.sync(function() print('SetModelAsNoLongerNeeded', m) end)
end)
Fx.runSync(Fx.resourceScope:extend(loadModel))
Fx.resourceScope:closeSync()
--> SetModelAsNoLongerNeeded prop_atm_01
```

### Services

A service is any value (usually a table of functions returning effects) looked up by a tag. Code asks for the service by yielding its tag; whoever runs the code provides it.

#### Fx.Tag(key)

```lua
Fx.Tag(key: string) -> Tag  -- Tag is an Effect<Service, never>
```

- **Parameters:** `key`, a name used in error messages.
- **Returns:** a tag. The tag is itself an effect that succeeds with the service: `Fx.yield(Bank)`, `Bank:flatMap(...)`.
- **Fails with:** a defect `Service not found: <key>. Provide it with :provide(layer) or :provideService(tag, impl).` when the service is not provided.
- **Notes:** tags are matched by identity, not by key. Two `Fx.Tag('Bank')` calls make two different tags; define each tag once and share it (for example in a shared file).

```lua
local Bank = Fx.Tag('Bank')
local function payday(src)
  return Fx.gen(function()
    local bank = Fx.yield(Bank)
    return Fx.yield(bank.deposit(src, 500))
  end)
end
local fakeBank = { deposit = function(src, n) return Fx.succeed(n + 1000) end }
print(Fx.runSync(payday(1):provideService(Bank, fakeBank))) --> 1500
local exit = Fx.runSyncExit(payday(1))
print((Fx.Cause.defects(exit.cause)[1]:match('^[^.]*'))) --> Service not found: Bank
```

#### Fx.isTag(value)

```lua
Fx.isTag(value: any) -> boolean
```

```lua
print(Fx.isTag(Fx.Tag('Garage')), Fx.isTag(Fx.unit)) --> true false
```

#### Fx.serviceOption(tag)

```lua
Fx.serviceOption(tag: Tag) -> Effect<Service | nil, never>
```

- **Returns:** the service when provided, else `nil`. Never fails.
- **Notes:** for optional dependencies, such as a metrics sink.

```lua
local Discord = Fx.Tag('Discord')
local notify = Fx.serviceOption(Discord):flatMap(function(d)
  if not d then return Fx.succeed('no webhook configured') end
  return d.post('robbery started')
end)
print(Fx.runSync(notify)) --> no webhook configured
```

#### eff:provideService(tag, service)

```lua
eff:provideService(tag: Tag, service: any) -> Effect<A, E>
```

- **Returns:** `eff` with `service` available under `tag`. Inner provides win over outer ones.

```lua
local Config = Fx.Tag('Config')
local eff = Config:map(function(c) return c.maxVehicles end):provideService(Config, { maxVehicles = 3 })
print(Fx.runSync(eff)) --> 3
```

#### eff:provideContext(ctx)

```lua
eff:provideContext(ctx: table<Tag, any>) -> Effect<A, E>
```

- **Parameters:** `ctx`, a table from tag to service, merged over the services already provided.
- **Notes:** `eff:provide(ctx)` with a plain table does the same. `Fx.Context.empty()`, `Fx.Context.add(ctx, tag, service)`, `Fx.Context.merge(a, b)` and `Fx.Context.get(ctx, tag)` build and read these tables without mutating their inputs.

```lua
local Bank, Garage = Fx.Tag('Bank'), Fx.Tag('Garage')
local ctx = Fx.Context.add(Fx.Context.add(Fx.Context.empty(), Bank, 'maze'), Garage, 'pillbox')
local eff = Fx.all({ Bank, Garage }):provideContext(ctx)
local r = Fx.runSync(eff)
print(r[1], r[2]) --> maze pillbox
```

### Layer

A layer is a recipe that builds services, possibly using other services and acquiring resources. Within one build, each layer object is built at most once even if it appears several times in the graph. Separate builds (two `eff:provide(layer)` calls, two runtimes) build it again.

#### Fx.Layer.succeed(tag, service)

```lua
Fx.Layer.succeed(tag: Tag, service: any) -> Layer
```

- **Returns:** a layer that provides `service` as is.

```lua
local Bank = Fx.Tag('Bank')
local BankLive = Fx.Layer.succeed(Bank, { name = 'Fleeca' })
print(Fx.runSync(Bank:provide(BankLive)).name) --> Fleeca
```

#### Fx.Layer.sync(tag, fn)

```lua
Fx.Layer.sync(tag: Tag, fn: fun(): any) -> Layer
```

- **Returns:** a layer that calls `fn` when it builds and provides the result.

```lua
local Shops = Fx.Tag('Shops')
local ShopsLive = Fx.Layer.sync(Shops, function() return { count = 12 } end)
print(Fx.runSync(Shops:provide(ShopsLive)).count) --> 12
```

#### Fx.Layer.effect(tag, eff)

```lua
Fx.Layer.effect(tag: Tag, eff: Effect<any, E>) -> Layer
```

- **Parameters:** `eff`, builds the service. It may yield other services (provided with `layer:provide(dep)`) and may fail.
- **Fails with:** a failing `eff` fails whatever the layer is provided to.
- **Notes:** for resources use `Layer.scoped`. `Fx.acquireRelease` inside `Layer.effect` uses the caller's `Scope` if there is one, otherwise it dies with `Service not found: Scope`.

```lua
local Config, Bank = Fx.Tag('Config'), Fx.Tag('Bank')
local ConfigLive = Fx.Layer.succeed(Config, { startingCash = 500 })
local BankLive = Fx.Layer.effect(Bank, Fx.gen(function()
  local cfg = Fx.yield(Config)
  return { open = function() return Fx.succeed(cfg.startingCash) end }
end)):provide(ConfigLive)
print(Fx.runSync(Fx.gen(function() return Fx.yield(Fx.yield(Bank).open()) end):provide(BankLive))) --> 500
```

#### Fx.Layer.scoped(tag, eff)

```lua
Fx.Layer.scoped(tag: Tag, eff: Effect<any, E>) -> Layer
```

- **Parameters:** `eff`, builds the service and may acquire resources with `Fx.acquireRelease`, `Fx.addFinalizer` or `forkScoped`.
- **Notes:** those resources are released when the layer's scope closes: when the effect given to `eff:provide(layer)` ends, or when a [Runtime](#runtime) is disposed or the resource stops.

```lua
local Db = Fx.Tag('Db')
local DbLive = Fx.Layer.scoped(Db, Fx.acquireRelease(
  Fx.sync(function() print('pool opened') return { query = function() return 42 end } end),
  function() return Fx.sync(function() print('pool closed') end) end))
local n = Fx.runSync(Db:map(function(db) return db.query() end):provide(DbLive))
print(n)
--> pool opened
--> pool closed
--> 42
```

#### Fx.Layer.effectDiscard(eff)

```lua
Fx.Layer.effectDiscard(eff: Effect<any, E>) -> Layer
```

- **Returns:** a layer that runs `eff` (in the layer's scope) when it builds and provides no service.
- **Notes:** for startup work tied to the layer's lifetime, such as a background loop started with `forkScoped`.

```lua
local Startup = Fx.Layer.effectDiscard(Fx.sync(function() print('shop blips created') end))
Fx.runSync(Fx.succeed('ok'):provide(Startup))
--> shop blips created
```

#### Fx.Layer.empty

```lua
Fx.Layer.empty: Layer
```

- **Notes:** provides nothing. Useful as a starting value when building layer lists.

```lua
print(Fx.runSync(Fx.succeed(1):provide(Fx.Layer.empty))) --> 1
```

#### Fx.Layer.merge(...)

```lua
Fx.Layer.merge(...: Layer) -> Layer
```

- **Returns:** a layer that provides every service of every layer given.
- **Notes:** the layers build one after another in argument order and do not see each other's services; use `layer:provide(dep)` for dependencies. When two layers provide the same tag, the later one wins.

```lua
local Bank, Garage = Fx.Tag('Bank'), Fx.Tag('Garage')
local App = Fx.Layer.merge(Fx.Layer.succeed(Bank, 'fleeca'), Fx.Layer.succeed(Garage, 'legion'))
local r = Fx.runSync(Fx.all({ Bank, Garage }):provide(App))
print(r[1], r[2]) --> fleeca legion
```

#### layer:provide(dep)

```lua
layer:provide(dep: Layer) -> Layer
```

- **Returns:** a layer that builds `dep` first and feeds its services into `layer`. The result provides only `layer`'s services.

```lua
local Config, Bank = Fx.Tag('Config'), Fx.Tag('Bank')
local ConfigLive = Fx.Layer.succeed(Config, { tax = 0.1 })
local BankLive = Fx.Layer.effect(Bank, Config:map(function(c) return { tax = c.tax } end)):provide(ConfigLive)
local exit = Fx.runSyncExit(Config:provide(BankLive))
print(Fx.runSync(Bank:provide(BankLive)).tax, exit._tag) --> 0.1 Failure
```

#### layer:provideMerge(dep)

```lua
layer:provideMerge(dep: Layer) -> Layer
```

- **Returns:** like `provide`, but the result provides the services of both `dep` and `layer`.

```lua
local Config, Bank = Fx.Tag('Config'), Fx.Tag('Bank')
local ConfigLive = Fx.Layer.succeed(Config, { tax = 0.1 })
local BankLive = Fx.Layer.effect(Bank, Config:map(function(c) return { tax = c.tax } end))
local Both = BankLive:provideMerge(ConfigLive)
local r = Fx.runSync(Fx.all({ Config, Bank }):provide(Both))
print(r[1].tax, r[2].tax) --> 0.1 0.1
```

#### layer:build(scope)

```lua
layer:build(scope: ScopeObject) -> Effect<table<Tag, any>, E>
```

- **Returns:** an effect that builds the layer into `scope` and succeeds with its context table (tag to service). Resources are released when `scope` closes.
- **Notes:** low level; `eff:provide` and `Fx.Runtime` call it for you.

```lua
local Bank = Fx.Tag('Bank')
local ctx = Fx.runSync(Fx.Layer.succeed(Bank, 'maze'):build(Fx.Scope.unsafeMake()))
print(ctx[Bank]) --> maze
```

#### eff:provide(layerOrContext)

```lua
eff:provide(what: Layer | table<Tag, any>) -> Effect<A, E>
```

- **Parameters:** `what`, a layer, or a plain context table (then it is `provideContext`).
- **Returns:** `eff` with the services provided.
- **Fails with:** the layer's build errors, plus the errors of `eff`.
- **Notes:** with a layer, the layer is built each time the effect runs, in a fresh scope that closes when `eff` ends. For services shared across many runs (event handlers, RPC handlers), build once with a [Runtime](#runtime).

```lua
local Counter = Fx.Tag('Counter')
local builds = 0
local CounterLive = Fx.Layer.sync(Counter, function() builds = builds + 1 return {} end)
local eff = Counter:provide(CounterLive)
Fx.runSync(eff)
Fx.runSync(eff)
print(builds) --> 2
```

### Runtime

A runtime builds a layer once and shares its services with every effect it runs. Make one per resource for your services and register it with [Fx.setRuntime](#fxsetruntimert) so `Fx.net` and `Fx.rpc` handlers get them.

#### Fx.Runtime.make(layer)

```lua
Fx.Runtime.make(layer: Layer) -> Runtime
```

- **Returns:** a runtime. The layer is not built yet: it builds on the first run, on its own root fiber; runs that arrive meanwhile wait for it.
- **Notes:** the runtime's scope is an ordinary open scope, so scoped resources in the layer are released on resource stop. If the build fails, the failure is logged once and every run of the runtime fails with that cause; the runtime does not rebuild.

```lua
local Counter = Fx.Tag('Counter')
local builds = 0
local rt = Fx.Runtime.make(Fx.Layer.sync(Counter, function() builds = builds + 1 return { n = 0 } end))
local bump = Counter:map(function(c) c.n = c.n + 1 return c.n end)
rt:runFork(bump)
rt:runFork(bump)
rt:runFork(bump, { onExit = function(exit) print(exit.value, builds) end })
--> 3 1
```

#### rt:runFork(eff, opts?)

```lua
rt:runFork(eff: Effect<A, E>, opts?: { onExit?: fun(exit: Exit<A>) }) -> Fiber
```

- **Returns:** a root fiber running `eff` with the runtime's services, as [Fx.runFork](#fxrunforkeff-opts).

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, { name = 'Pacific Standard' }))
rt:runFork(Bank, { onExit = function(exit) print(exit.value.name) end }) --> Pacific Standard
```

#### rt:runCallback(eff, cb)

```lua
rt:runCallback(eff: Effect<A, E>, cb: fun(exit: Exit<A>)) -> Fiber
```

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, 'fleeca'))
rt:runCallback(Bank, function(exit) print(exit._tag, exit.value) end) --> Success fleeca
```

#### rt:runAwait(eff)

```lua
rt:runAwait(eff: Effect<A, E>) -> A
```

- **Returns:** the value, blocking the calling Citizen thread. Raises like [Fx.runAwait](#fxrunawaiteff-opts).

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, { balance = function(src) return Fx.succeed(src * 100) end }))
CreateThread(function()
  local bal = rt:runAwait(Fx.gen(function() return Fx.yield(Fx.yield(Bank).balance(3)) end))
  print('balance', bal)
end)
--> balance 300
```

#### rt:context() and rt:wrap(eff)

```lua
rt:context() -> Effect<table<Tag, any>, E>
rt:wrap(eff: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** `context` succeeds with the built context table (building it on first use). `wrap` returns `eff` with the runtime's services provided, to run it some other way.

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, 'maze'))
Fx.runFork(rt:wrap(Bank), { onExit = function(exit) print(exit.value) end }) --> maze
```

#### rt:dispose()

```lua
rt:dispose() -> Effect<nil, never>
```

- **Returns:** an effect that closes the runtime's scope, releasing everything its layer acquired.
- **Notes:** disposing does not reset the runtime. Later runs still receive the services that were built before, even though their resources have been released. Make a new runtime instead of reusing a disposed one.

```lua
local Db = Fx.Tag('Db')
local rt = Fx.Runtime.make(Fx.Layer.scoped(Db, Fx.acquireRelease(Fx.succeed('pool'), function()
  return Fx.sync(function() print('pool closed') end)
end)))
rt:runFork(Db, { onExit = function(exit)
  print('got', exit.value)
  Fx.runFork(rt:dispose())
end })
--> got pool
--> pool closed
```

<a id="schedule"></a>

## Schedule
This page covers `Fx.Schedule`, the policies that decide how often and with what delay an effect is retried after a failure (`eff:retry`) or repeated after a success (`eff:repeatWith`). Use it for database deadlocks, flaky HTTP calls, waiting for a resource to come up, autosaves and periodic jobs. For values over time, see [Streams](#streams) (`Fx.Stream.fromSchedule`).

Examples print values with a `--> result` comment showing what they print.

### How a schedule works

A schedule is a table `{ initial = state, step = fun(state, input, now) }`. After each run of the effect, `step` is called with the current state, an input (the **error** for `retry`, the **value** for `repeatWith`) and the current game time in ms. It returns three values:

1. `continue` (boolean): run again?
2. `delayMs` (number): how long to wait before the next run (`0` runs again at once, without a tick in between);
3. `nextState`.

The first run always happens; the schedule only decides about the runs after it. Schedules are immutable values: each `retry` or `repeatWith` starts from `initial`, so one schedule can be shared by many effects.

### Constructors

#### Fx.Schedule.spaced(ms) and Fx.Schedule.fixed(ms)

```lua
Fx.Schedule.spaced(ms: integer) -> Schedule
Fx.Schedule.fixed(ms: integer) -> Schedule
```

- **Returns:** a schedule that continues forever with a delay of `ms` each time. `fixed` is the same function as `spaced`: the delay is counted from the end of each run, not on a fixed clock.

```lua
local ticks = 0
local autosave = Fx.sync(function() ticks = ticks + 1 end):repeatWith(Fx.Schedule.spaced(30000))
Fx.runFork(autosave:timeoutOption(100000), { onExit = function() print(ticks) end }) --> 4
```

#### Fx.Schedule.forever

```lua
Fx.Schedule.forever: Schedule
```

- **Notes:** continues forever with no delay. Combine it with `take`, `whileInput` or `upTo`, or the effect loops without waiting.

```lua
local n = 0
local count = Fx.sync(function() n = n + 1 return n end):repeatWith(Fx.Schedule.forever:take(4))
print(Fx.runSync(count)) --> 5
```

#### Fx.Schedule.recurs(n) and Fx.Schedule.once

```lua
Fx.Schedule.recurs(n: integer) -> Schedule
Fx.Schedule.once: Schedule  -- recurs(1)
```

- **Returns:** a schedule that continues `n` times with no delay. With `retry`, that is `n` retries (`n + 1` attempts); with `repeatWith`, `n` repeats (`n + 1` runs).

```lua
local attempts = 0
local ping = Fx.suspend(function() attempts = attempts + 1 return Fx.fail('timeout') end)
Fx.runSyncExit(ping:retry(Fx.Schedule.once))
print(attempts) --> 2
```

#### Fx.Schedule.exponential(base, factor?)

```lua
Fx.Schedule.exponential(base: integer, factor?: number) -> Schedule  -- factor defaults to 2
```

- **Returns:** a schedule that continues forever with delays `base`, `base*factor`, `base*factor^2`, ... (rounded down).
- **Notes:** pair it with `take(n)`, `upTo(ms)` or `maxDelay(ms)`.

```lua
local s = Fx.Schedule.exponential(100)
local st, delays = s.initial, {}
for i = 1, 4 do
  local _, d, nextSt = s.step(st, nil, 0)
  delays[i], st = d, nextSt
end
print(table.concat(delays, ' ')) --> 100 200 400 800
```

#### Fx.Schedule.fibonacci(base)

```lua
Fx.Schedule.fibonacci(base: integer) -> Schedule
```

- **Returns:** a schedule that continues forever with delays `base`, `base`, `2*base`, `3*base`, `5*base`, `8*base`, ...

```lua
local s = Fx.Schedule.fibonacci(100)
local st, delays = s.initial, {}
for i = 1, 6 do
  local _, d, nextSt = s.step(st, nil, 0)
  delays[i], st = d, nextSt
end
print(table.concat(delays, ' ')) --> 100 100 200 300 500 800
```

#### Fx.Schedule.make(initial, step)

```lua
Fx.Schedule.make(initial: S, step: fun(state: S, input: any, now: integer): (boolean, integer, S)) -> Schedule
```

- **Parameters:** `initial`, the starting state. `step`, as described in [How a schedule works](#how-a-schedule-works).
- **Returns:** a custom schedule. It has all the methods below.

```lua
-- Retry while the error says the player is still loading, 250 ms apart, at most 20 times.
local whileLoading = Fx.Schedule.make(0, function(count, err)
  return count < 20 and err == 'still loading', 250, count + 1
end)
local tries = 0
local getCharacter = Fx.suspend(function()
  tries = tries + 1
  if tries < 4 then return Fx.fail('still loading') end
  return Fx.succeed({ name = 'Ana' })
end)
Fx.runFork(getCharacter:retry(whileLoading), { onExit = function(exit) print(exit.value.name, tries) end })
--> Ana 4
```

### Combinators

Every combinator returns a new schedule; the original is unchanged.

#### schedule:take(n)

```lua
schedule:take(n: integer) -> Schedule
```

- **Returns:** the same delays, stopping after at most `n` recurrences. Same as `schedule:intersect(Fx.Schedule.recurs(n))`.

```lua
local attempts = 0
local eff = Fx.suspend(function() attempts = attempts + 1 return Fx.fail('busy') end)
Fx.runFork(eff:retry(Fx.Schedule.spaced(100):take(3)), { onExit = function() print(attempts) end }) --> 4
```

#### schedule:intersect(other)

```lua
schedule:intersect(other: Schedule) -> Schedule
```

- **Returns:** a schedule that continues only while **both** continue, using the **longer** of the two delays.

```lua
local s = Fx.Schedule.exponential(100):intersect(Fx.Schedule.spaced(250))
local _, d1, st = s.step(s.initial, nil, 0)
local _, d2 = s.step(st, nil, 0)
print(d1, d2) --> 250 250
```

#### schedule:union(other)

```lua
schedule:union(other: Schedule) -> Schedule
```

- **Returns:** a schedule that continues while **either** continues. When both continue it uses the **shorter** delay; when only one does, that one's delay.

```lua
local quickThenSlow = Fx.Schedule.spaced(100):take(2):union(Fx.Schedule.spaced(1000):take(4))
local st, delays = quickThenSlow.initial, {}
for i = 1, 5 do
  local c, d, nextSt = quickThenSlow.step(st, nil, 0)
  delays[i], st = c and d or 'stop', nextSt
end
print(table.concat(delays, ' ')) --> 100 100 1000 1000 stop
```

#### schedule:jittered(min?, max?)

```lua
schedule:jittered(min?: number, max?: number) -> Schedule  -- defaults 0.8 and 1.2
```

- **Returns:** the same schedule with each delay multiplied by a random factor between `min` and `max` (using `math.random`), rounded down.
- **Notes:** spreads retries from many players so they do not hit a service at the same moment.

```lua
local s = Fx.Schedule.spaced(1000):jittered()
local _, d = s.step(s.initial, nil, 0)
print(d >= 800 and d <= 1200) --> true
```

#### schedule:maxDelay(ms)

```lua
schedule:maxDelay(ms: integer) -> Schedule
```

- **Returns:** the same schedule with every delay capped at `ms`.

```lua
local s = Fx.Schedule.exponential(500):maxDelay(2000)
local st, delays = s.initial, {}
for i = 1, 5 do
  local _, d, nextSt = s.step(st, nil, 0)
  delays[i], st = d, nextSt
end
print(table.concat(delays, ' ')) --> 500 1000 2000 2000 2000
```

#### schedule:upTo(ms)

```lua
schedule:upTo(ms: integer) -> Schedule
```

- **Returns:** the same schedule, stopping once the next run would start more than `ms` after the first step.
- **Notes:** the clock starts at the first call to `step`, which is after the first run finished (for `retry`, at the first failure), not when the effect started.

```lua
local attempts = 0
local connect = Fx.suspend(function() attempts = attempts + 1 return Fx.fail('refused') end)
Fx.runFork(connect:retry(Fx.Schedule.spaced(1000):upTo(3500)), {
  onExit = function(exit) print(attempts, Fx.Cause.failureOption(exit.cause)) end,
})
--> 4 refused
```

#### schedule:whileInput(pred)

```lua
schedule:whileInput(pred: fun(input: any): boolean) -> Schedule
```

- **Returns:** the same schedule, continuing only while `pred(input)` is true. The input is the error for `retry` and the value for `repeatWith`.

```lua
local Busy = Fx.TaggedError('Busy')
local attempts = 0
local eff = Fx.suspend(function()
  attempts = attempts + 1
  if attempts == 2 then return Fx.fail('fatal: account frozen') end
  return Busy {}:fail()
end)
local onlyBusy = Fx.Schedule.spaced(50):whileInput(function(e) return Busy.is(e) end)
Fx.runFork(eff:retry(onlyBusy), { onExit = function(exit) print(attempts, Fx.Cause.failureOption(exit.cause)) end })
--> 2 fatal: account frozen
```

### Policies

`retry` and `repeatWith` accept:

| Policy | Meaning |
|---|---|
| a number `n` | `Fx.Schedule.recurs(n)`: `n` more runs, no delay |
| a `Schedule` | used as is |
| a table `{ schedule?, times?, while?, until? }` | `schedule` (default `Fx.Schedule.forever`), then `:take(times)`, then `:whileInput(while)`, then `:whileInput(not until(input))` |

`while` and `until` are Lua keywords, so write them as `['while']` and `['until']`. A table with only `while` or `until` and no `times` retries without limit and without delay while the predicate allows.

#### eff:retry(policy)

```lua
eff:retry(policy: integer | Schedule | { schedule?: Schedule, times?: integer, ['while']?: fun(err): boolean, ['until']?: fun(err): boolean }) -> Effect<A, E>
```

- **Parameters:** `policy`, see [Policies](#policies). The schedule's input is the error.
- **Returns:** an effect that runs `eff`, and after each expected failure asks the schedule whether to run it again and how long to wait first.
- **Fails with:** the last error, once the schedule stops.
- **Notes:** only expected failures are retried. Defects and interruptions end the effect at once. The wait between attempts is an `Fx.sleep`, so interrupting the fiber stops the retry loop.

```lua
local DbBusy = Fx.TaggedError('DbBusy')
local attempts = 0
local saveCharacter = Fx.suspend(function()
  attempts = attempts + 1
  if attempts < 3 then return DbBusy {}:fail() end
  return Fx.succeed('saved')
end)
local policy = {
  schedule = Fx.Schedule.exponential(200):jittered(),
  times = 5,
  ['while'] = function(e) return DbBusy.is(e) end,
}
Fx.runFork(saveCharacter:retry(policy), { onExit = function(exit) print(exit.value, attempts) end })
--> saved 3
```

#### eff:repeatWith(schedule)

```lua
eff:repeatWith(schedule: integer | Schedule | { schedule?: Schedule, times?: integer, ['while']?: fun(value): boolean, ['until']?: fun(value): boolean }) -> Effect<A, E>
```

- **Parameters:** `schedule`, a policy as above. The schedule's input is the value of the last run.
- **Returns:** an effect that runs `eff`, then runs it again after each success as the schedule allows, and succeeds with the value of the last run.
- **Fails with:** the first failure, which stops the repeat.
- **Notes:** `eff['repeat'](eff, schedule)` is the same function (`repeat` is a Lua keyword).

```lua
local fuel = 100
local drive = Fx.sync(function() fuel = fuel - 30 return fuel end)
local untilEmpty = drive:repeatWith { schedule = Fx.Schedule.spaced(1000), ['until'] = function(left) return left <= 0 end }
Fx.runFork(untilEmpty, { onExit = function(exit) print('fuel left', exit.value) end }) --> fuel left -20
```

#### eff:repeatN(n)

```lua
eff:repeatN(n: integer) -> Effect<A, E>
```

- **Returns:** an effect that runs `eff` `n + 1` times in total, with no delay, and succeeds with the last value.

```lua
local horn = 0
print(Fx.runSync(Fx.sync(function() horn = horn + 1 return horn end):repeatN(2))) --> 3
```

<a id="schema"></a>

## Schema
This page covers `Fx.S` (also available as `Fx.Schema`), runtime validation for anything that crosses a trust boundary: net event payloads, RPC input and output, NUI messages, convars, config files, KVP and state bags. A schema checks a value and returns a cleaned copy with defaults and transforms applied, or a message that says what is wrong and where. `Fx.net.handle`, `Fx.rpc.register`, `Fx.nui.handle`, `Fx.config`, `Fx.kvp` and `Fx.state` take these schemas directly (see [Net and RPC](#net-events-and-rpc) and [FiveM modules](#players-config-assets-entities)).

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

### Rules that apply everywhere

- **Output is a copy.** Containers (`struct`, `array`, `tuple`, `record`, `tagged`) build new tables. The input is never modified.
- **Unknown struct fields are dropped** by default. `S.struct(fields, { extra = 'error' })` rejects them and `{ extra = 'keep' }` passes them through unchecked. See [S.struct](#sstructfields-opts).
- **Missing means `nil`.** A struct field that is absent is checked as `nil`, so it fails unless the field schema is `optional()`, has a `default(...)`, or accepts `nil` (`S.unknown`, `S.any`, `S['nil']`).
- **`nil` is handled before the type check.** For a `nil` input, a `default` is used if there is one, else `optional()` accepts it; refinements do not run. So `S.int:optional():min(1)` and `S.int:min(1):optional()` both accept `nil`.
- **Defaults are not validated.** The default value (or the result of the default function) is returned as is, without type checks, refinements or transforms.
- **Schemas are immutable.** Every modifier returns a new schema; the original is unchanged and can be reused.
- **Refinements are not type guards.** They run after the base check and compare with Lua operators, so put them on the right base type. `S.string:min(1)` or `S.int:minLen(1)` raise a Lua error (`attempt to compare ...`) when validated, instead of returning `false`.
- **Fields are checked in sorted key order**, and the first problem is reported.

### Error messages

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

### Checking values

#### schema:validate(input)

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

#### schema:decode(input)

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

#### schema:parse(input)

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

#### schema:is(input)

```lua
schema:is(input: any) -> boolean
```

- **Returns:** `true` when the input passes. Only the boolean, no value.

```lua
local S = Fx.S
print(S.netId:is(12), S.netId:is(0)) --> true false
```

### Primitives

#### S.string

```lua
S.string: Schema<string>
```

- **Notes:** any Lua string. Use `minChars`/`maxChars` for user-visible length and `minLen`/`maxLen` for byte length.

```lua
print(Fx.S.string:validate(5)) --> false expected string, got 5
```

#### S.number

```lua
S.number: Schema<number>
```

- **Notes:** any finite number. NaN, `math.huge` and `-math.huge` are rejected. Strings are not converted.

```lua
local S = Fx.S
print(S.number:is(1.5), S.number:is(0 / 0), S.number:is('1')) --> true false false
```

#### S.int and S.integer

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

#### S.boolean

```lua
S.boolean: Schema<boolean>
```

```lua
print(Fx.S.boolean:validate('true')) --> false expected boolean, got "true"
```

#### S.unknown and S.any

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

#### S['nil']

```lua
S['nil']: Schema<nil>
```

- **Notes:** accepts only `nil` (`nil` is a Lua keyword, hence the brackets).

```lua
print(Fx.S['nil']:validate(1)) --> false expected nil, got 1
```

### Literals

#### S.literal(...)

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

#### S.enum(list)

```lua
S.enum(list: any[]) -> Schema<any>
```

- **Parameters:** a list of allowed values. Same as `S.literal(table.unpack(list))`.

```lua
local Account = Fx.S.enum { 'cash', 'bank', 'crypto' }
print(Account:validate('gold')) --> false expected "cash" | "bank" | "crypto", got "gold"
```

### Containers

#### S.array(item)

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

#### S.tuple(...)

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

#### S.struct(fields, opts?)

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

#### S.record(keySchema, valueSchema)

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

#### S.union(...)

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

#### S.tagged(field, variants)

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

#### S.lazy(fn)

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

### FiveM types

#### S.vector2, S.vector3 and S.vector4

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

#### S.hash

```lua
S.hash: Schema<integer>
```

- **Notes:** accepts an integer hash as is, or a non-empty string that is hashed with `joaat` (or `GetHashKey` when `joaat` is missing). Floats and empty strings are rejected. Outside FiveM, where neither function exists, a string is returned unchanged.

```lua
local S = Fx.S
print(S.hash:is('adder'), S.hash:is(-1216765807), S.hash:is('')) --> true true false
```

#### S.netId

```lua
S.netId: Schema<integer>  -- S.int:positive()
```

- **Notes:** a network id: a positive integer. It does not check that the entity exists; use `Fx.entity.fromNetId` for that ([FiveM modules](#players-config-assets-entities)).

```lua
print(Fx.S.netId:validate(0)) --> false must be positive
```

#### S.player

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

### Modifiers

#### schema:optional()

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

#### schema:default(value)

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

#### schema:describe(text)

```lua
schema:describe(text: string) -> Schema<T>
```

- **Returns:** the same schema with a `description` field set to `text`. It does not change validation.

```lua
print(Fx.S.int:describe('Amount in dollars').description) --> Amount in dollars
```

#### schema:refine(pred, message?)

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

#### schema:transform(fn)

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

### Refinements

All refinements are built on `refine` and keep the path prefix. Numeric ones need a number base (`S.number`, `S.int`); length ones need a string or table base; `pattern`, `minChars` and `maxChars` need a string base.

#### schema:min(n), schema:max(n) and schema:between(lo, hi)

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

#### schema:positive() and schema:nonNegative()

```lua
schema:positive() -> Schema<T>     -- > 0; message: must be positive
schema:nonNegative() -> Schema<T>  -- >= 0; message: must be >= 0
```

```lua
local S = Fx.S
print(S.number:positive():is(0), S.int:nonNegative():is(0)) --> false true
```

#### schema:minLen(n), schema:maxLen(n) and schema:len(n)

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

#### schema:minItems(n), schema:maxItems(n) and schema:maxEntries(n)

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

#### schema:nonEmpty()

```lua
schema:nonEmpty() -> Schema<T>  -- minLen(1); message: length must be >= 1
```

```lua
print(Fx.S.string:nonEmpty():validate('')) --> false length must be >= 1
```

#### schema:minChars(n) and schema:maxChars(n)

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

#### schema:pattern(p, message?)

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

### Schemas in tagged errors

`Fx.TaggedError(tag, fields)` takes a table of schemas and checks every instance when it is built; see [Errors](#fxtaggederrortag-fields).

```lua
local S = Fx.S
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney', { need = S.int })
print(pcall(NotEnoughMoney, { need = 'x' })) --> false invalid fields for NotEnoughMoney: need: expected integer, got "x"
```

<a id="streams"></a>

## Streams
`Fx.Stream` describes zero or more values over time: game events, net events, state bag changes, security events, timers, queues. This page covers every source, operator and runner, plus the FiveM sources `Fx.net.stream`, `StateKey:changes` and `Fx.security.stream`. Use a stream when you would otherwise write an event handler with hand-rolled batching, debouncing, cleanup or rate limiting. For a single value use an effect instead ([Effects](#effects)).

### How streams run

A stream is a description. Nothing happens until you run it with one of the `run*` methods, which return an effect, and that effect runs on a fiber like any other (`Fx.runFork`, `Fx.yield`, `Fx.runAwait`). Running the same stream twice runs it twice from the start, with its own handlers and buffers.

```lua
local s = Fx.Stream.range(1, 3):map(function(x) return x * 10 end)
Fx.runFork(s:runForEach(print))   -- prints 10, 20, 30
Fx.runFork(s:runForEach(print))   -- runs again from the start: 10, 20, 30
```

Values may be `nil`. A `nil` value is still a value: it is counted, passed to callbacks, and leaves a hole in `runCollect`'s list.

#### Ordering

- Each value goes through the whole pipeline, including the effect returned by your `runForEach` callback, before the next value is taken. A stream never handles two values at once. `mapEffect` and `tap` run their effects one at a time, in order.
- Values keep the order their source produced them in. The one exception is `merge`, which interleaves several sources by arrival time (each source keeps its own order).
- A slow consumer slows the stream down. What happens to values that arrive meanwhile depends on the source (next section).

#### Back-pressure and buffers

| Source or operator | While the consumer is busy |
|---|---|
| `make`, `fromTable`, `range`, `iterate`, `fromEffect`, `repeatEffect` | Nothing is produced. The next value is computed only when the consumer asks for it. |
| `interval`, `fromSchedule` | The next wait starts after the consumer has handled the previous value, so a slow consumer stretches the period. |
| `fromQueue` | Values wait in the queue, under the queue's own capacity and strategy ([Concurrency](#concurrency)). |
| `fromPubSub` | Each run has its own buffer: unbounded by default, or `opts.buffer` with `opts.strategy`. The publisher never waits. |
| `async`, `event`, `Fx.net.stream`, `StateKey:changes` | Values wait in a buffer of `opts.buffer` (default 1024). When it is full, `strategy = 'sliding'` (default) drops the oldest value, `'dropping'` drops the newest. |
| `Fx.security.stream`, `Fx.trace.stream` | Buffer of `opts.buffer` (default 1024), always sliding. |
| `merge`, `groupedWithin`, `debounce` | The upstream runs on its own fiber and feeds an internal queue of 16 values. When that queue is full the upstream waits. Upstream can run up to about 16 values ahead of what the consumer has taken. |
| `interruptAfter` | Same, with an internal queue of 1. |

#### Stopping

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

### Sources

#### Fx.Stream.make(...)

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

#### Fx.Stream.fromTable(list)

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

#### Fx.Stream.range(from, to)

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

#### Fx.Stream.iterate(seed, f)

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

#### Fx.Stream.empty

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

#### Fx.Stream.never

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

#### Fx.Stream.fail(err)

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

#### Fx.Stream.fromEffect(eff)

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

#### Fx.Stream.repeatEffect(eff)

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

#### Fx.Stream.interval(ms)

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

#### Fx.Stream.fromSchedule(schedule)

```lua
Fx.Stream.fromSchedule(schedule: Fx.Schedule): Fx.Stream<integer>
```

- **Parameters:** `schedule`, a schedule ([Schedule](#schedule)).
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

#### Fx.Stream.fromQueue(q)

```lua
Fx.Stream.fromQueue(q: Fx.Queue): Fx.Stream<any>
```

- **Parameters:** `q`, a queue ([Concurrency](#concurrency)).
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

#### Fx.Stream.fromPubSub(ps, opts)

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

#### Fx.Stream.async(register, opts)

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

#### Fx.Stream.event(name, shape, opts)

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

#### Fx.Stream.merge(...)

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

#### Fx.Stream.fromRun(run)

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

#### Fx.Stream.isStream(v)

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

### FiveM sources

#### Fx.net.stream(name, schema, opts)

```lua
Fx.net.stream(
  name: string,
  schema: Fx.Schema,
  opts?: { rateLimit?: string|false, buffer?: integer, strategy?: 'sliding'|'dropping' }
): Fx.Stream<{ source: integer, input: any }>   -- server
): Fx.Stream<any>                                -- client: the input
```

- **Parameters:** `name`, the net event; `schema`, required (pass `Fx.S.unknown` to accept anything on purpose); `opts.rateLimit`, server only, per player, `"10/s"` by default, `false` to turn it off ([format](#fxratelimiterparsespec)); `opts.buffer` and `opts.strategy` as in `Fx.Stream.async`.
- **Returns:** on the server, a stream of `{ source = src, input = input }`; on the client, a stream of the input.
- **Fails with:** never. Rejected events are dropped, not failures.
- **Notes:** both sides. Raises at call time when `schema` is not a schema. The net event handler is registered when the stream starts and removed when it stops. Each event goes through the same checks as [`Fx.net.handle`](#fxnethandlename-schema-handler-opts), in this order: on the server, events without a player `source` (a server-side `TriggerEvent`) are ignored, then the rate limit is checked (a rejected payload still uses a token), then the schema. Server rejections become `rate_limited` or `invalid_payload` [security events](#fxsecurity); on the client a payload that fails the schema is logged as a warning. Each run has its own rate limiter. Unlike `Fx.net.handle`, there is no span per event and nothing is tied to the player's scope.

```lua
-- server: radio channel joins, validated and rate limited
Fx.runFork(Fx.net.stream('radio:join', Fx.S.struct { channel = Fx.S.int:between(1, 999) }, { rateLimit = '3/s' })
  :runForEach(function(m) return Radio.join(m.source, m.input.channel) end))
```

#### StateKey:changes(opts)

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
- **Notes:** both sides. Uses `StateKey:onChange`: values that fail the key's schema never reach the stream; on the server, an invalid value written by a client is reported as an `invalid_state` security event. Clearing a key emits a change with `value = nil`. The state bag change handler is added when the stream starts and removed (`RemoveStateBagChangeHandler`) when it stops. See [FiveM modules](#players-config-assets-entities) for `Fx.state`.

```lua
-- client: react to job changes, but not to every flicker
local Job = Fx.state.key('job', Fx.S.struct { name = Fx.S.string, grade = Fx.S.int })

Fx.runFork(Job:changes({ bag = Fx.state.player() })
  :debounce(250)
  :runForEach(function(change) return Hud.setJob(change.value) end))
```

#### Fx.security.stream(opts)

```lua
Fx.security.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.SecurityEvent>
```

- **Parameters:** `opts.buffer`, how many events may wait for a slow consumer (default 1024). Past that the oldest are dropped; the strategy is always sliding.
- **Returns:** the security events published in this resource after the stream starts.
- **Fails with:** never.
- **Notes:** both sides, but the library only reports events on the server. Never ends by itself. See [Fx.security](#fxsecurity) for event kinds and fields. `Fx.trace.stream` works the same way for finished spans ([Observability](#metrics-tracing-logs)).

```lua
-- post bad payloads to a webhook in batches: when 20 have piled up,
-- or 10 s after the first of a batch, whichever comes first
Fx.runFork(Fx.security.stream()
  :filter(function(ev) return ev.kind ~= 'rate_limited' end)
  :groupedWithin(20, 10000)
  :runForEach(function(batch) return Webhook.post(batch) end))
```

### Operators

Operators return a new stream and leave the original unchanged.

#### stream:map(f)

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

#### stream:mapEffect(f)

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

#### stream:filter(pred)

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

#### stream:filterMap(f)

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

#### stream:tap(f)

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

#### stream:take(n)

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

#### stream:takeWhile(pred)

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

#### stream:takeUntil(pred)

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

#### stream:drop(n)

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

#### stream:dropWhile(pred)

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

#### stream:scan(init, f)

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

#### stream:changes(eq)

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

#### stream:grouped(n)

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

#### stream:groupedWithin(n, ms)

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

#### stream:debounce(ms)

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

#### stream:throttle(ms)

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

#### stream:flatMap(f)

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

#### stream:concat(that)

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

#### stream:catchAll(f)

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

#### stream:ensuring(fin)

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

#### stream:interruptAfter(ms)

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

### Running

Each runner returns an effect. Run it with `Fx.runFork`, `Fx.yield` inside `Fx.gen`, or `Fx.runAwait` from a Citizen thread ([Effects](#effects)).

#### stream:runForEach(f)

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

#### stream:runForEachWhile(f)

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

#### stream:runDrain()

```lua
stream:runDrain(): Fx.Effect<nil, E>
```

- **Returns:** an effect that runs the stream for its effects and ignores the values.
- **Fails with:** the stream's failure.
- **Notes:** both sides.

```lua
Fx.runFork(Fx.Stream.interval(60000):mapEffect(function() return Inventory.flushDirty() end):runDrain())
```

#### stream:runCollect()

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

#### stream:runFold(init, f)

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

#### stream:runCount()

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

#### stream:runHead()

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

#### stream:runLast()

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

#### stream:runFork(f)

```lua
stream:runFork(f?: fun(v: A): Fx.Effect<any, E>|any): Fx.Effect<Fx.Fiber, never>
```

- **Parameters:** `f`, optional, as in `runForEach`.
- **Returns:** an effect that starts `runForEach(f)` on a new child fiber and succeeds with the fiber at once.
- **Fails with:** never (the fiber carries the stream's outcome).
- **Notes:** both sides. This is `stream:runForEach(f):fork()`: the fiber is a child of the fiber that ran this effect and is interrupted when that fiber finishes. To run a stream for the life of the resource, use `Fx.runFork(stream:runForEach(f))` instead ([Concurrency](#concurrency)).

```lua
Fx.runFork(Fx.gen(function()
  -- the heartbeat runs while this fiber waits for the round to end
  local beat = Fx.yield(Fx.Stream.interval(5000):runFork(function() TriggerClientEvent('round:beat', -1) end))
  Fx.yield(Round.waitForEnd())
  Fx.yield(beat:interrupt())
end))
```

<a id="metrics-tracing-logs"></a>

## Metrics, tracing and logs
Rivo FX records spans around effects, keeps counters, gauges and histograms per resource, and writes levelled logs that carry the current trace. This page covers tracing (`eff:withSpan`, `Fx.span`, `Fx.trace.*`), metrics (`Fx.metrics.*`, `trackDuration`, `trackErrors`), logging (`Fx.log.*`, `Fx.logInfo` and friends), the spans and metrics the library records by itself, and the `rivo_fx` HTTP endpoint that serves them to Prometheus. Use it to find out where time goes, what failed and how often.

### Tracing

A span records a name, a start and end time (Unix ms), a status and attributes. The span an effect runs in is the parent of the spans it starts, including spans on fibers it forks. `Fx.rpc` carries the caller's span to the host as a W3C `traceparent`, so a client call and the server handler it reaches share one trace. Finished spans go to `Fx.trace.on` listeners, `Fx.trace.stream()`, and a ring buffer of the last 200 per resource (`Fx.trace.recent()`). Tracing is per resource and per side.

A finished span is a table:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | span name |
| `traceId` | string | 32 lowercase hex characters |
| `spanId` | string | 16 lowercase hex characters |
| `parentSpanId` | string? | parent span, `nil` for a root span |
| `kind` | string | `'internal'` (default), `'server'`, `'client'`, `'producer'` or `'consumer'` |
| `startTime`, `endTime` | integer | Unix ms |
| `status` | string | `'ok'`, `'error'` or `'unset'` |
| `message` | string? | on error: the error tag, the error as a string, or the first line of a defect (at most 256 characters, then `...`) |
| `attributes` | table | your attributes, plus `fx.error` and `fx.interrupted` (below) |
| `events` | table? | `{ name, time, attributes }` added with `span:addEvent` |
| `resource` | string | the resource that recorded it |
| `seq` | integer | order of finishing in this resource |

How an effect's outcome sets the status:

| Outcome | `status` | Extra |
|---|---|---|
| success | `'ok'` | |
| failure with a tagged error declared in this resource with `Fx.TaggedError` | `'error'` | `message` and `attributes['fx.error']` are the tag |
| failure with a tagged error rebuilt from the wire whose tag this resource never declared | `'error'` | `message` is the tag, `attributes['fx.error'] = 'error'` |
| failure with any other expected error | `'error'` | `message = tostring(err)`, no `fx.error` |
| defect | `'error'` | `attributes['fx.error'] = 'defect'` |
| interruption | `'unset'` | `attributes['fx.interrupted'] = true` |

#### eff:withSpan(name, opts)

```lua
eff:withSpan(name: string, opts?: {
  attributes?: table<string, any>,
  kind?: 'internal'|'server'|'client'|'producer'|'consumer',
  parent?: Fx.Span|string,   -- a span or a W3C traceparent string
  root?: boolean,            -- start a new trace
}): Fx.Effect<A, E>
```

- **Parameters:** `name`, the span name; `opts.attributes`, copied onto the span; `opts.kind` (default `'internal'`); `opts.parent`, a span or traceparent string to continue instead of the current span; `opts.root = true` to start a new trace even inside another span.
- **Returns:** an effect that runs `eff` inside a new span and has the same result.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. The span starts when the effect runs, not when `withSpan` is called, so each run makes a new span. A `parent` string that does not parse starts a new trace instead of failing. When tracing is off, `eff` runs unchanged. An interruption at any point either finds no span or finishes it; no span is left open.

```lua
local function deposit(src, amount)
  return Bank.credit(src, amount)
    :withSpan('bank.deposit', { attributes = { amount = amount, player = src } })
end
```

#### Fx.span(name, fn, opts)

```lua
Fx.span(name: string, fn: fun(...): Fx.Effect<A, E>, opts?: Fx.SpanOptions): fun(...): Fx.Effect<A, E>
```

- **Parameters:** `name`, the span name; `fn`, a function that returns an effect; `opts`, as in `withSpan`.
- **Returns:** a function with the same arguments as `fn`. Each call returns `fn(...)`'s effect inside a span.
- **Fails with:** whatever `fn`'s effect fails with. A raising `fn` fails the effect.
- **Notes:** both sides. `fn` runs when the effect runs, not when the wrapper is called.

```lua
local deposit = Fx.span('bank.deposit', function(src, amount)
  return Fx.annotateCurrentSpan('amount', amount):zipRight(Bank.credit(src, amount))
end)

Fx.runFork(deposit(source, 500))
```

#### Fx.currentSpan

```lua
Fx.currentSpan: Fx.Effect<Fx.Span|nil, never>
```

- **Returns:** an effect (a value, not a function) that succeeds with the span the fiber runs in, or `nil`.
- **Fails with:** never.
- **Notes:** both sides. Use it to add events or read ids.

```lua
local job = Fx.gen(function()
  local span = Fx.yield(Fx.currentSpan)
  if span then span:addEvent('cache miss', { key = 'garage:12' }) end
  return Fx.yield(Garage.load(12))
end):withSpan('garage.load')
```

#### Fx.annotateCurrentSpan(key, value)

```lua
Fx.annotateCurrentSpan(key: string, value: any): Fx.Effect<nil, never>
```

- **Parameters:** `key`, the attribute name; `value`, its value.
- **Returns:** an effect that sets the attribute on the current span.
- **Fails with:** never.
- **Notes:** both sides. Does nothing outside a span.

```lua
Fx.rpc.register('shop:buy', { input = BuyInput }, function(src, input)
  return Fx.annotateCurrentSpan('item', input.item)
    :zipRight(Shop.buy(src, input.item, input.qty))
end)
```

#### span:setAttribute(key, value)

```lua
span:setAttribute(key: string, value: any): Fx.Span
```

- **Parameters:** `key`, `value`.
- **Returns:** the span, for chaining.
- **Fails with:** never.
- **Notes:** both sides. Plain function on a span table from `Fx.currentSpan`, `Fx.trace.start` or a listener.

```lua
local span = Fx.trace.start('import vehicles')
span:setAttribute('rows', 120):setAttribute('source', 'csv')
Fx.trace.finish(span)
```

#### span:addEvent(name, attributes)

```lua
span:addEvent(name: string, attributes?: table): Fx.Span
```

- **Parameters:** `name`, the event name; `attributes`, optional.
- **Returns:** the span.
- **Fails with:** never.
- **Notes:** both sides. Each event gets the current Unix ms time. At most 32 events per span; later ones are ignored.

```lua
Fx.yield(Fx.currentSpan):addEvent('model loaded', { model = 'adder' })
```

#### span:traceparent()

```lua
span:traceparent(): string
```

- **Returns:** the W3C traceparent of the span: `00-<traceId>-<spanId>-01`.
- **Fails with:** never.
- **Notes:** both sides. Pass it to another system, or as `opts.parent` to continue the trace.

```lua
local tp = Fx.yield(Fx.currentSpan):traceparent()
PerformHttpRequest(url, cb, 'POST', body, { ['traceparent'] = tp })
```

#### Fx.trace.on(fn)

```lua
Fx.trace.on(fn: fun(span: Fx.Span)): fun()
```

- **Parameters:** `fn`, called with each finished span of this resource.
- **Returns:** a function that removes the listener.
- **Fails with:** never. An error raised by `fn` is reported as a defect and does not reach the span's effect.
- **Notes:** both sides. Called synchronously when the span ends; keep it short.

```lua
local stop = Fx.trace.on(function(span)
  if span.status == 'error' then
    print(('span %s failed: %s'):format(span.name, span.message))
  end
end)
```

#### Fx.trace.stream(opts)

```lua
Fx.trace.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.Span>
```

- **Parameters:** `opts.buffer`, how many spans may wait for a slow consumer (default 1024; past that the oldest are dropped).
- **Returns:** a stream of spans finished after it starts. Never ends by itself.
- **Fails with:** never.
- **Notes:** both sides. See [Streams](#streams).

```lua
-- server: ship slow spans to a log service in batches
Fx.runFork(Fx.trace.stream()
  :filter(function(s) return s.endTime - s.startTime > 250 end)
  :groupedWithin(50, 10000)
  :runForEach(function(batch) return LogShipper.send(batch) end))
```

#### Fx.trace.recent(after)

```lua
Fx.trace.recent(after?: integer): Fx.Span[]
```

- **Parameters:** `after`, optional `seq`; only spans with a greater `seq` are returned.
- **Returns:** the most recent finished spans of this resource, oldest first, at most 200.
- **Fails with:** never.
- **Notes:** both sides. The buffer keeps the last 200 spans; older ones are overwritten.

```lua
local last = 0
RegisterCommand('slowspans', function()
  for _, s in ipairs(Fx.trace.recent(last)) do
    last = s.seq
    if s.endTime - s.startTime > 100 then print(s.name, s.endTime - s.startTime) end
  end
end, true)
```

#### Fx.trace.start(name, parent, opts)

```lua
Fx.trace.start(name: string, parent?: Fx.Span|{ traceId: string, spanId: string }, opts?: {
  attributes?: table<string, any>,
  kind?: 'internal'|'server'|'client'|'producer'|'consumer',
}): Fx.Span
```

- **Parameters:** `name`; `parent`, a span or a parsed traceparent (from `Fx.trace.parseTraceparent`), or `nil` for a new trace; `opts.attributes` (copied) and `opts.kind`.
- **Returns:** a new open span with status `'unset'`.
- **Fails with:** never.
- **Notes:** both sides. A plain function, for code outside effects. End it with `Fx.trace.finish`. It is not the current span of any fiber. `parent` must be a table: a traceparent string is not parsed here and silently starts a new trace. Prefer `eff:withSpan`, which starts and finishes for you.

```lua
AddEventHandler('onResourceStart', function(res)
  local span = Fx.trace.start('resource start', nil, { attributes = { resource = res } })
  -- ... plain Lua work
  Fx.trace.finish(span)
end)
```

#### Fx.trace.finish(span, exit)

```lua
Fx.trace.finish(span: Fx.Span, exit?: Fx.Exit)
```

- **Parameters:** `span`, from `Fx.trace.start`; `exit`, optional, sets the status from an effect's outcome (see the status table above).
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Without `exit`, the status stays `'unset'`. Finishing a span twice does nothing the second time. The span then goes to listeners, `Fx.trace.stream()` and `Fx.trace.recent()`.

```lua
local span = Fx.trace.start('nightly cleanup')
Fx.runFork(Cleanup.run(), { onExit = function(exit) Fx.trace.finish(span, exit) end })
```

#### Fx.trace.parseTraceparent(s)

```lua
Fx.trace.parseTraceparent(s: string): { traceId: string, spanId: string, remote: true }|nil
```

- **Parameters:** `s`, a W3C traceparent (`00-<32 hex>-<16 hex>-<2 hex>`, 55 characters).
- **Returns:** the ids (lowercased) with `remote = true`, or `nil` when `s` is not a string, has the wrong length or shape, uses version `ff`, or has an all-zero trace or span id.
- **Fails with:** never.
- **Notes:** both sides. The result works as `parent` for `Fx.trace.start`.

```lua
local parent = Fx.trace.parseTraceparent(headers['traceparent'])
local span = Fx.trace.start('webhook', parent, { kind = 'server' })
```

#### Fx.trace.traceparentOf(fiber)

```lua
Fx.trace.traceparentOf(fiber: Fx.Fiber): string|nil
```

- **Parameters:** `fiber`.
- **Returns:** the traceparent of the span the fiber runs in, or `nil`.
- **Fails with:** never.
- **Notes:** both sides. `Fx.rpc` uses it to fill the request's `trace` field. A fiber from `Fx.runFork` has not run yet when `runFork` returns, so this gives `nil` until the fiber has entered its span.

```lua
local worker = Fx.runFork(Jobs.worker():withSpan('job worker'))

RegisterCommand('workertrace', function()
  print(Fx.trace.traceparentOf(worker))   -- 00-<traceId>-<spanId>-01
end, true)
```

#### Fx.trace.failedSpanOf(cause)

```lua
Fx.trace.failedSpanOf(cause: Fx.Cause): Fx.Span|nil
```

- **Parameters:** `cause`, a failure cause.
- **Returns:** the innermost span that failed with this cause (or a cause inside it), or `nil`.
- **Fails with:** never.
- **Notes:** both sides. Used to link an unhandled fiber failure, reported after its spans have closed, to the span that raised it. Interruptions are not linked. A failure caught and raised again is a new cause.

```lua
Fx.runFork(Job.run(), { onExit = function(exit)
  if exit._tag == 'Failure' then
    local span = Fx.trace.failedSpanOf(exit.cause)
    Fx.log.error('job failed', { span = span and span.name, traceId = span and span.traceId })
  end
end })
```

#### Fx.trace.setEnabled(on)

```lua
Fx.trace.setEnabled(on: boolean)
Fx.trace.isEnabled(): boolean
```

- **Parameters:** `on`, `true` to record spans, `false` to stop.
- **Returns:** nothing; `isEnabled()` returns the current setting.
- **Fails with:** never.
- **Notes:** both sides, per resource. Overrides the `rivo_fx:tracing` convar. While off, `withSpan` and `Fx.span` run the effect without a span (so `Fx.currentSpan` gives `nil` in new work) and RPC calls and handlers record no spans.

```lua
-- turn tracing off in a hot resource during an event
Fx.trace.setEnabled(false)
```

#### Fx.trace.nowMs()

```lua
Fx.trace.nowMs(): integer
```

- **Returns:** Unix ms, from the platform clock anchored once to the wall clock (`os.time`, or `GetCloudTimeAsInt` on clients where `os.time` is not usable).
- **Fails with:** never.
- **Notes:** both sides. This is the clock span times use.

```lua
local t0 = Fx.trace.nowMs()
```

#### Fx.trace.CurrentSpan

```lua
Fx.trace.CurrentSpan: Fx.Tag   -- 'rivo_fx/CurrentSpan'
```

- **Returns:** the service tag that holds the current span in a fiber's context.
- **Fails with:** never.
- **Notes:** both sides. `withSpan` provides it. Providing it yourself makes a span from `Fx.trace.start` the parent of spans inside an effect.

```lua
local span = Fx.trace.start('batch import')
Fx.runFork(Import.all():provideService(Fx.trace.CurrentSpan, span),
  { onExit = function(exit) Fx.trace.finish(span, exit) end })
```

#### Trace propagation over Fx.rpc

- Every `Fx.rpc.call` / `Fx.rpc.callClient` runs in a span `rpc.client <name>` (kind `client`, attributes `rpc.name`, `rpc.target`, and `player` for `callClient`). It is a child of the caller's current span.
- The request carries that span's traceparent in its `trace` field.
- The host runs the handler in a span `rpc.server <name>` (kind `server`, attributes `rpc.name`, `rpc.caller`, and `player` on the server) whose parent is the caller's span. A `trace` that is missing, not a string, longer than 64 characters or malformed starts a new trace; the request is still answered.
- The Lua and JS implementations use the same field, so traces join across languages. See [Net events and RPC](#net-events-and-rpc).

```lua
-- client: the 'open bank' span, the rpc.client span and the server's
-- rpc.server span all share one traceId
Fx.runFork(Fx.rpc.call('bank:balance', {}):withSpan('open bank'))
```

#### Convar rivo_fx:tracing

```cfg
set rivo_fx:tracing off
```

- `off` (exactly) stops span recording in every resource that loads Rivo FX on that side; any other value, or unset, leaves it on.
- Read once, when the resource starts. `Fx.trace.setEnabled` overrides it at run time.
- Clients only see replicated convars, so use `setr rivo_fx:tracing off` to turn it off on clients too.

### Metrics

Metrics live per resource and per side. A metric name may be defined more than once in a resource: the same kind returns the existing metric (its first options are kept), a different kind raises.

Names must match `^[a-zA-Z_:][a-zA-Z0-9_:]*$`; label names must match `^[a-zA-Z_][a-zA-Z0-9_]*$` and label values are turned into strings. Each distinct label set is one series.

**Series limit.** A metric holds at most 1000 series. Updates that would create series number 1001 or later are dropped, and one warning is logged for that metric. This keeps a label a client controls (a player id, a payload field) from growing memory without bound. Avoid such labels anyway.

Metric methods do not check the metric's kind; call the ones listed for it.

#### Fx.metrics.counter(name, opts)

```lua
Fx.metrics.counter(name: string, opts?: { help?: string }): Fx.Counter
```

- **Parameters:** `name`; `opts.help`, the description shown in Prometheus.
- **Returns:** a counter: a value that only goes up. Methods: `inc`, `value`, `update`.
- **Fails with:** never; raises on an invalid name or when `name` is already another kind.
- **Notes:** both sides.

```lua
local Deposits = Fx.metrics.counter('bank_deposits_total', { help = 'Deposits made' })
Deposits:inc(1, { account = 'main' })
```

#### Fx.metrics.gauge(name, opts)

```lua
Fx.metrics.gauge(name: string, opts?: {
  help?: string,
  collect?: fun(): number | { { labels: table, value: number } | { [1]: table, [2]: number } },
}): Fx.Gauge
```

- **Parameters:** `name`; `opts.help`; `opts.collect`, a function that computes the gauge each time metrics are read, returning a number (one series without labels) or a list of `{ labels, value }` (or `{ labels = ..., value = ... }`) entries.
- **Returns:** a gauge: a value that goes up and down. Methods: `set`, `add`, `value`, `update`.
- **Fails with:** never; raises on an invalid name or kind clash.
- **Notes:** both sides. With `collect`, `set`/`add` values are not reported and `value()` returns 0; only `collect`'s result appears in `snapshot()`. Entries whose value is not a number are skipped. A raising `collect` is reported as a defect and the gauge reports no series.

```lua
Fx.metrics.gauge('garage_vehicles_out', {
  help = 'Vehicles spawned from garages, by garage',
  collect = function()
    local out = {}
    for name, g in pairs(Garages) do out[#out + 1] = { labels = { garage = name }, value = g.out } end
    return out
  end,
})
```

#### Fx.metrics.histogram(name, opts)

```lua
Fx.metrics.histogram(name: string, opts?: { help?: string, buckets?: number[] }): Fx.Histogram
```

- **Parameters:** `name`; `opts.help`; `opts.buckets`, ascending upper bounds (default `{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }`).
- **Returns:** a histogram: counts of observations per bucket, plus sum and count. Methods: `observe`, `update`.
- **Fails with:** never; raises on an invalid name, kind clash, or buckets that do not ascend.
- **Notes:** both sides. An observation `v` counts in the first bucket with `v <= bound`, or above every bucket. The default buckets suit milliseconds.

```lua
local Latency = Fx.metrics.histogram('bank_deposit_ms', { help = 'Deposit time', buckets = { 5, 25, 100, 500 } })
```

#### counter:inc(n, labels)

```lua
counter:inc(n?: number, labels?: table<string, any>)
```

- **Parameters:** `n`, how much to add (default 1); `labels`, the series.
- **Returns:** nothing.
- **Fails with:** never; raises when `n` is negative or a label name is invalid.
- **Notes:** both sides. Plain function, runs at once.

```lua
Deposits:inc()                         -- no labels
Deposits:inc(2, { account = 'savings' })
```

#### gauge:set(v, labels)

```lua
gauge:set(v: number, labels?: table<string, any>)
```

- **Parameters:** `v`, the value; `labels`, the series.
- **Returns:** nothing.
- **Fails with:** never; raises when `v` is not a number.
- **Notes:** both sides.

```lua
local Online = Fx.metrics.gauge('players_online')
AddEventHandler('playerJoining', function() Online:set(#GetPlayers()) end)
```

#### gauge:add(n, labels)

```lua
gauge:add(n: number, labels?: table<string, any>)
```

- **Parameters:** `n`, may be negative; `labels`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides.

```lua
local InQueue = Fx.metrics.gauge('queue_players')
InQueue:add(1)    -- joined the queue
InQueue:add(-1)   -- left it
```

#### histogram:observe(v, labels)

```lua
histogram:observe(v: number, labels?: table<string, any>)
```

- **Parameters:** `v`, one observation; `labels`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. For timing effects use `eff:trackDuration`.

```lua
local Payouts = Fx.metrics.histogram('job_payout', { buckets = { 100, 500, 1000, 5000 } })
Payouts:observe(750, { job = 'trucker' })
```

#### metric:value(labels)

```lua
counter:value(labels?: table<string, any>): number
gauge:value(labels?: table<string, any>): number
```

- **Parameters:** `labels`, the series.
- **Returns:** the current value of a counter or gauge series, 0 when it was never set.
- **Fails with:** never.
- **Notes:** both sides. Returns 0 for histograms and for gauges with `collect`; read those with `Fx.metrics.snapshot()`.

```lua
print(Deposits:value({ account = 'main' }))
```

#### metric:update(v, labels)

```lua
counter:update(n?: number, labels?): Fx.Effect<nil, never>
gauge:update(v: number, labels?): Fx.Effect<nil, never>
histogram:update(v: number, labels?): Fx.Effect<nil, never>
```

- **Parameters:** as `inc` (counter), `set` (gauge) or `observe` (histogram).
- **Returns:** an effect that does the update when it runs.
- **Fails with:** never (invalid arguments raise when it runs, which is a defect).
- **Notes:** both sides. For use inside pipelines.

```lua
local Sold = Fx.metrics.counter('shop_items_sold_total')
local buy = Shop.buy(src, item):tap(function() return Sold:update(1, { item = item }) end)
```

#### eff:trackDuration(histogram, labels)

```lua
eff:trackDuration(histogram: Fx.Histogram, labels?: table<string, any>): Fx.Effect<A, E>
```

- **Parameters:** `histogram`; `labels`, the series.
- **Returns:** an effect with the same result that observes how long `eff` took, in ms.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. Observes every outcome: success, failure and interruption. Time comes from the platform clock.

```lua
local Latency = Fx.metrics.histogram('bank_deposit_ms', { buckets = { 5, 25, 100, 500 } })
local function deposit(src, amount)
  return Bank.credit(src, amount):trackDuration(Latency, { account = 'main' })
end
```

#### eff:trackErrors(counter, labels)

```lua
eff:trackErrors(counter: Fx.Counter, labels?: table<string, any>): Fx.Effect<A, E>
```

- **Parameters:** `counter`; `labels`, extra labels added to every count.
- **Returns:** an effect with the same result that adds 1 to `counter` each time `eff` fails.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. Interruptions are not counted. The `error` label is the `_tag` of an error declared in this resource with `Fx.TaggedError`; `'error'` for any other tagged error (one rebuilt from another side, whose tag a client could make up); `'defect'` for defects; `'unknown'` for other failures. A label you pass named `error` replaces it.

```lua
local Failures = Fx.metrics.counter('bank_failures_total', { help = 'Failed bank operations' })
local function withdraw(src, amount)
  return Bank.withdraw(src, amount):trackErrors(Failures, { op = 'withdraw' })
end
-- after a NotEnoughMoney failure:
-- bank_failures_total{error="NotEnoughMoney",op="withdraw"} 1
```

#### Fx.metrics.snapshot()

```lua
Fx.metrics.snapshot(): {
  name: string,
  kind: 'counter'|'gauge'|'histogram',
  help: string,
  buckets?: number[],
  series: ({ labels: table<string, string>, value: number }
         | { labels: table<string, string>, counts: integer[], sum: number, count: integer })[],
}[]
```

- **Returns:** every metric of this resource, in definition order, with copies of its series. Counter and gauge series have `value`. Histogram series have `counts` per bucket (not cumulative; the last entry counts observations above every bucket), `sum` and `count`.
- **Fails with:** never.
- **Notes:** both sides. Runs every gauge's `collect`. Includes the built-in metrics.

```lua
for _, m in ipairs(Fx.metrics.snapshot()) do
  if m.name == 'bank_deposit_ms' then
    for _, s in ipairs(m.series) do print(s.labels.account, s.count, s.sum / s.count) end
  end
end
```

#### Fx.metrics.prometheus(extraLabels, snapshot)

```lua
Fx.metrics.prometheus(extraLabels?: table<string, string>, snapshot?: Fx.MetricSnapshot[]): string
```

- **Parameters:** `extraLabels`, added to every series that does not set them itself (for example `{ resource = 'bank' }`); `snapshot`, what to render (default `Fx.metrics.snapshot()`).
- **Returns:** the Prometheus text format (version 0.0.4), ending in a newline.
- **Fails with:** never.
- **Notes:** both sides. `# HELP` is written only when `help` is set. Labels are sorted by name; a histogram's `le` comes last. Histograms are rendered as cumulative `_bucket` lines plus `+Inf`, `_sum` and `_count`. NaN and infinities are rendered as `NaN`, `+Inf` and `-Inf`. On the server you normally scrape the [HTTP endpoint](#http-endpoint) instead.

```lua
print(Fx.metrics.prometheus({ resource = GetCurrentResourceName() }))
-- # HELP bank_deposits_total Deposits made
-- # TYPE bank_deposits_total counter
-- bank_deposits_total{account="main",resource="bank"} 3
```

### Logging

`Fx.log` writes levelled, structured log lines. The minimum level comes from the convar `rivo_fx:logLevel`: `debug`, `info` (default), `warn`, `error` or `none`, case-insensitive; an unknown value means `info`. It is read when the resource first uses `Fx.log`. On clients, use `setr` so the convar replicates. Each line is printed as `[LEVEL] message key=value ...` with colour codes, fields sorted by key; tables are inspected.

Error records reach the `/fxdev` devtools' Failures view whatever the level and sink.

#### Fx.log.info(msg, fields)

```lua
Fx.log.debug(msg: string, fields?: table)
Fx.log.info(msg: string, fields?: table)
Fx.log.warn(msg: string, fields?: table)
Fx.log.error(msg: string, fields?: table)
```

- **Parameters:** `msg`, the message; `fields`, optional key/value pairs.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Plain functions that write at once. Records below the level are dropped. Inside effects prefer `Fx.logInfo` and friends, which add the fiber and trace ids.

```lua
Fx.log.info('garage opened', { src = source, garage = 'pillbox' })
-- [INFO] garage opened garage=pillbox src=3
Fx.log.error('db down', { query = 'SELECT 1' })
```

#### Fx.log.setLevel(level)

```lua
Fx.log.setLevel(level: 'debug'|'info'|'warn'|'error'|'none')
Fx.log.getLevel(): string
```

- **Parameters:** `level`, case-insensitive.
- **Returns:** nothing; `getLevel()` returns the current level.
- **Fails with:** never; raises on an unknown level.
- **Notes:** both sides, per resource. Overrides the convar.

```lua
RegisterCommand('bankdebug', function() Fx.log.setLevel('debug') end, true)
```

#### Fx.log.setSink(fn)

```lua
Fx.log.setSink(fn: (fun(level: string, msg: string, fields?: table))|nil)
```

- **Parameters:** `fn`, receives each record at or above the level instead of printing it; `nil` restores printing.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides, per resource. Also receives the library's own logs (rejected payloads, failed handlers).

```lua
Fx.log.setSink(function(level, msg, fields)
  if level == 'error' then exports.discord_logs:send(msg, json.encode(fields or {})) end
  print(('[%s] %s'):format(level, msg))
end)
```

#### Fx.logInfo(msg, fields)

```lua
Fx.logDebug(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logInfo(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logWarn(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logError(msg: string, fields?: table): Fx.Effect<nil, never>
```

- **Parameters:** as `Fx.log.*`.
- **Returns:** an effect that writes the record when it runs.
- **Fails with:** never.
- **Notes:** both sides. Adds `fiber` (the fiber id) and, inside a span, `traceId` and `spanId`, so a log line leads to its trace. Your `fields` are merged on top.

```lua
Fx.rpc.register('garage:take', { input = TakeInput }, function(src, input)
  return Fx.gen(function()
    Fx.yield(Fx.logInfo('taking vehicle', { src = src, plate = input.plate }))
    return Fx.yield(Garage.take(src, input.plate))
  end)
end)
-- [INFO] taking vehicle fiber=12 plate=RIVO001 spanId=... src=3 traceId=...
```

### Built-in spans and metrics

Spans:

| Span | Kind | Where | Attributes |
|---|---|---|---|
| `rpc.client <name>` | `client` | caller of `Fx.rpc.call` / `callClient` | `rpc.name`, `rpc.target`, `player` (`callClient`) |
| `rpc.server <name>` | `server` | RPC host, child of the caller's span | `rpc.name`, `rpc.caller`, `player` (server) |
| `net <name>` | `server` | `Fx.net.handle`, only when the handler returns an effect (both sides) | `net.event`, `player` (server) |

Metrics. Each is defined when its module is first used in the resource:

| Metric | Kind | Labels | Meaning |
|---|---|---|---|
| `rivo_fx_rpc_handler_ms` | histogram | `name`, `outcome` | RPC handler time on the host |
| `rivo_fx_rpc_call_ms` | histogram | `name`, `outcome` | RPC round trip seen by the caller |
| `rivo_fx_net_events_total` | counter | `name` | net events that passed their checks (`Fx.net.handle`, `Fx.net.stream`) |
| `rivo_fx_security_events_total` | counter | `kind` | rejected client input ([security events](#fxsecurity)) |
| `rivo_fx_fibers` | gauge | | root fibers alive in this resource |
| `rivo_fx_timers` | gauge | | timers waiting in the fiber runner |

`outcome` is `ok`, `interrupted`, the error tag when this resource declared it (the `Rpc*` tags count), `error` for any other tagged error, or `defect`.

### HTTP endpoint

The `rivo_fx` resource serves the metrics and recent spans of every server-side resource that uses Rivo FX, over the server's HTTP port:

| Request | Response |
|---|---|
| `GET /rivo_fx/metrics` | Prometheus text format (`text/plain; version=0.0.4`). Every resource's metrics merged, each series labelled `resource="<name>"` unless it sets `resource` itself. |
| `GET /rivo_fx/spans?limit=N` | JSON array of recent spans across resources, newest first. `limit` defaults to 100, at most 1000. Each resource contributes its last 200. |

- Off until the server convar `rivo_fx:metricsToken` is set; until then every request gets `404`. Set it with `set`, not `setr`, so it never reaches clients. It is read on each request.
- Requests must send `Authorization: Bearer <token>`; otherwise `401` with `WWW-Authenticate: Bearer`. The comparison is constant time.
- Methods other than `GET` get `405`; other paths `404`; an internal error `500`.
- When two resources define a metric with different kinds (or different histogram buckets), the first resource's definition is kept and the other's series are skipped.
- Client metrics and spans are not served here; see them in `/fxdev`.
- Span JSON fields: `seq`, `name`, `traceId`, `spanId`, `parentSpanId`, `kind`, `startTime`, `endTime`, `status`, `message`, `attributes`, `events`, `resource`, `side`. Attribute values are reduced to plain data (functions become strings, depth and size are capped).

```cfg
## server.cfg
ensure rivo_fx
set rivo_fx:metricsToken "a-long-random-string"   # set, not setr: keep it off clients
```

```yaml
## prometheus.yml
scrape_configs:
  - job_name: fivem
    metrics_path: /rivo_fx/metrics
    authorization: { credentials: a-long-random-string }
    static_configs: [{ targets: ['your-server:30120'] }]
```

```sh
curl -H 'Authorization: Bearer a-long-random-string' 'http://your-server:30120/rivo_fx/spans?limit=20'
```

### Convars

| Convar | Values | Default | Read |
|---|---|---|---|
| `rivo_fx:tracing` | `off` to stop recording spans | on | at resource start; `Fx.trace.setEnabled` overrides |
| `rivo_fx:logLevel` | `debug`, `info`, `warn`, `error`, `none` | `info` | on first use of `Fx.log`; `Fx.log.setLevel` overrides |
| `rivo_fx:metricsToken` | bearer token for the HTTP endpoint (server, `set` only) | unset: endpoint off | on every request |

<a id="devtools"></a>

## Devtools (/fxdev)
`/fxdev` is an in-game view of every resource that uses Rivo FX, on the server and on your own client: live fibers, traces, failures and metrics. Use it while building or debugging a resource on a dev server; only players with the `rivo_fx.devtools` ACE can open it.

### Opening it

```cfg
## server.cfg
add_ace group.admin rivo_fx.devtools allow
```

| Command | What it does |
|---|---|
| `/fxdev` | opens on the last view, or closes when open |
| `/fxdev <view>` | opens on (or switches to) `overview`, `fibers`, `traces`, `failures` or `metrics` |

The server checks the ACE on every request, not only when opening. A player without it sees a chat message naming the permission. `Esc` closes the screen; `/` focuses the filter.

### Views

| View | Shows |
|---|---|
| Overview | each resource and side with live fibers, timers, finished spans, failures and the last failure; a live-fibers chart for the last 60 seconds |
| Fibers | the fibers alive right now, each child under its parent, with status (`waiting`, `running`, `interrupting`), age, child count and the span it is in |
| Traces | recent traces as a waterfall; a client's `Fx.rpc` call and the server handler it reached are one trace. Click a span for its attributes, events and traceparent |
| Failures | error logs, unhandled fiber failures and defects, with the full cause, fields, fiber and a link to the trace |
| Metrics | every metric and label set; histograms with count, average, p50, p95 and p99 |

Controls: show the server, the client or both; filter by resource or name; pause updates; switch between the dark and light theme (remembered). In Traces, "errors only" hides traces without a failed span.

### Busy servers

- The overview lists the busiest resources first (failures, then live fibers, then spans) and stops at 50 rows until you choose "Show all". Column headers sort.
- Fibers fold into one group per resource and side; with more than 60 fibers the groups start folded. At most 400 fiber rows are drawn until "Show all", and each resource sends at most its first 200.
- The same failure message from one resource is one row with a count.
- Metric families show 8 label sets until "Show all".
- `rivo_fx` itself is not listed.

### What it costs

It asks for data once a second while open and not at all when closed. When collecting takes longer (hundreds of resources), the interval grows with the measured cost, up to every 5 seconds, and the status line says so. Spans and failures are sent once each; every resource keeps the last 200 spans and 50 failures.

### Privacy

Spans and failures can hold player ids, payload fields and error details. Give the ACE only to people who can already read your server console. All text is shown as text, never as HTML, so a player-controlled string cannot run in an admin's screen.

### Notes

- JS/TS resources (`@rivolabs/fx`) do not appear in `/fxdev` yet.
- Span times come from each side's own clock. The waterfall places a span from another clock (for example the server inside a client call) inside its parent and marks it with `~`.

See [Metrics, tracing and logs](#metrics-tracing-logs) for the spans and metrics behind these views.

<a id="net-events-and-rpc"></a>

## Net events and RPC
`Fx.net` registers net events that validate their payload against a schema and rate limit each player before your handler runs. `Fx.rpc` adds request/response calls over net events, with timeouts, cancellation and tagged errors that arrive on the caller as the same tag. `Fx.security` reports what the server rejected, `Fx.RateLimiter` is the token bucket behind the rate limits, and `Fx.compat` bridges ox_lib callbacks while you migrate. Use these for anything a player can send: never trust a client payload without a schema.

Schemas are covered in [Schema](#schema), effects and tagged errors in [Effects](#effects) and [Errors](#errors-and-causes). The wire format is specified in [docs/PROTOCOL.md](https://github.com/RivoLabs/rivo_fx/blob/main/docs/PROTOCOL.md); a summary is at the [end of this page](#wire-protocol-summary).

### Fx.net

#### Fx.net.handle(name, schema, handler, opts)

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
  - `opts.runtime`, the [Runtime](#scopes-services-layers) whose services the handler's effect gets.
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

#### Fx.net.stream(name, schema, opts)

```lua
Fx.net.stream(name: string, schema: Fx.Schema, opts?: {
  rateLimit?: string|false, buffer?: integer, strategy?: 'sliding'|'dropping',
}): Fx.Stream<{ source: integer, input: any }>   -- server; the input on the client
```

- **Parameters:** as `Fx.net.handle`, plus `opts.buffer` (default 1024) and `opts.strategy` (`'sliding'` default, or `'dropping'`) for values waiting on a slow consumer.
- **Returns:** a stream of the events that pass the same checks as `Fx.net.handle`.
- **Fails with:** never.
- **Notes:** both sides. The handler is registered while the stream runs and removed when it stops. No span per event and no player scoping. Full reference in [Streams](#fxnetstreamname-schema-opts).

```lua
-- server
Fx.runFork(Fx.net.stream('radio:join', Fx.S.struct { channel = Fx.S.int:between(1, 999) })
  :runForEach(function(m) return Radio.join(m.source, m.input.channel) end))
```

#### Fx.net.send(name, ...)

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

#### Fx.net.broadcast(name, payload)

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

#### Fx.net.emit(name, ...)

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

#### Fx.net.isSchema(v)

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

### Fx.rpc

An RPC has a host, which registers a handler, and a caller. Clients call server RPCs with `Fx.rpc.call`; the server calls client RPCs with `Fx.rpc.callClient`. Lua and JS ([JS](#javascript-typescript)) resources speak the same protocol, so a Lua client can call a TypeScript server RPC.

#### Fx.rpc.register(name, spec, handler)

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
- **Notes:** both sides (client hosts are called with `callClient`). Registering the same name again replaces the handler. The handler's result is sent back as the value. If it fails with a tagged error, that error (its serialisable fields) is sent and rebuilt on the caller with the same `_tag`; raising a tagged error with `error(NotEnoughMoney { ... })` works the same. Defects, raised non-tagged errors and output that fails `spec.output` are logged on the host and reach the caller as `RpcInternalError` with no details. The handler runs on its own fiber in a span `rpc.server <name>` that continues the caller's trace ([Observability](#trace-propagation-over-fxrpc)), and its time is recorded in `rivo_fx_rpc_handler_ms{name,outcome}`. On the server the fiber is interrupted when the player drops. When the caller cancels or the fiber is interrupted, no response is sent. A second request with the same caller and id while the first still runs is ignored. Tagged error fields go to the client as they are: do not put secrets in them.

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

#### Fx.rpc.call(name, input, opts)

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

#### Fx.rpc.callClient(player, name, input, opts)

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

#### Built-in error tags

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

#### RPC wire behaviour and cancellation

- Each resource that registers or calls RPCs listens on `__rfx:<res>:req`, `__rfx:<res>:res` and `__rfx:<res>:cancel`, where `<res>` is its resource name.
- A call sends `{ id, name, from, input, trace }` to `__rfx:<target>:req`, where `<target>` is `opts.resource` or the caller's own resource. The host replies to `__rfx:<from>:res` with `{ id, ok = true, value }` or `{ id, ok = false, error = { _tag, ... } }`.
- On the server, requests, cancels and responses without a player `source` are ignored.
- The host checks each request in order and stops at the first problem: a malformed envelope is dropped with no reply (on the server, an `invalid_payload` security event named `__rfx:<res>:req`); an unknown name replies `RpcNotFound` (server: `unknown_rpc`, not rate limited); the rate limit replies `RpcRateLimited` (`rate_limited`); invalid input replies `RpcInvalidInput` (`invalid_payload`).
- Cancellation: when the calling fiber is interrupted (by the timeout too), the caller sends `{ id, from }` to `__rfx:<target>:cancel`. The host interrupts the handler for that caller and id if it is still running and sends nothing back.

### Fx.security

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
| `invalid_state` | a client wrote a value that fails a `Fx.state.key` schema to its own player or entity bag ([FiveM modules](#players-config-assets-entities)) |

#### Fx.security.on(fn)

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

#### Fx.security.stream(opts)

```lua
Fx.security.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.SecurityEvent>
```

- **Parameters:** `opts.buffer`, events that may wait for a slow consumer (default 1024; past that the oldest are dropped).
- **Returns:** a stream of security events reported after it starts.
- **Fails with:** never.
- **Notes:** both sides. See [Streams](#fxsecuritystreamopts).

```lua
Fx.runFork(Fx.security.stream()
  :filter(function(ev) return ev.kind ~= 'rate_limited' end)
  :groupedWithin(20, 10000)
  :runForEach(function(batch) return Webhook.post(batch) end))
```

#### Fx.security.subscribe()

```lua
Fx.security.subscribe(): Fx.Effect<Fx.Queue, never>   -- requires Scope
```

- **Returns:** an effect that subscribes a queue to security events until the enclosing Scope closes.
- **Fails with:** never.
- **Notes:** both sides. The queue is unbounded. Prefer `Fx.security.stream()`, which bounds its buffer. See [Resources](#scopes-services-layers) for scopes.

```lua
Fx.runFork(Fx.scoped(Fx.gen(function()
  local q = Fx.yield(Fx.security.subscribe())
  while true do
    local ev = Fx.yield(q:take())
    print('security', ev.kind, ev.source)
  end
end)))
```

#### Fx.security.setQuiet(quiet)

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

#### Fx.security.report(ev)

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

#### The rivo_fx:security event

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

### Fx.RateLimiter

Token buckets keyed by anything, usually the player id. A spec is `"<n>/s"`, `"<n>/m"` or `"<n>/h"`: capacity `n`, refilled continuously at `n` per period. Each `Fx.net.handle`, `Fx.net.stream` run and `Fx.rpc.register` has its own limiter, so the effective bucket is one per player per event or RPC.

#### Fx.RateLimiter.new(spec)

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

#### Fx.RateLimiter.parse(spec)

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

#### limiter:take(key)

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

#### limiter:forget(key)

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

### Fx.compat

Interop with ox_lib callbacks, for moving a codebase over step by step. Needs `@ox_lib/init.lua` loaded in the same resource.

#### spec.libCallback (Fx.rpc.register)

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

#### Fx.compat.libCallback(name, ...)

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

#### Fx.compat.opts(t)

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

### Wire protocol summary

The full specification, shared by the Lua and JS implementations, is [docs/PROTOCOL.md](https://github.com/RivoLabs/rivo_fx/blob/main/docs/PROTOCOL.md). In short:

- A net event from `Fx.net` is a plain FiveM net event with exactly one argument, the payload, decoded with the receiver's schema before the handler runs.
- RPC uses three events per resource: `__rfx:<res>:req` carries `{ id, name, from, input, trace? }`, `__rfx:<res>:res` carries `{ id, ok, value }` or `{ id, ok, error }`, and `__rfx:<res>:cancel` carries `{ id, from }`.
- Only tagged errors cross the wire, with their `_tag` and serialisable fields. Defects become `RpcInternalError` without details.
- `trace` is the caller's W3C traceparent (at most 64 characters); a bad one starts a new trace and never rejects the request.
- Rate limits are token buckets per player and per event or RPC name, written `"<n>/s"`, `"<n>/m"` or `"<n>/h"`, default `"10/s"`.

<a id="players-config-assets-entities"></a>

## Players, config, assets, entities, ticks
This page covers the Rivo FX modules that wrap FiveM's game and server lifecycle: per-player scopes (`Fx.player`), resource stop (`Fx.onStop`, `Fx.resourceScope`), typed convars and config files (`Fx.config`), streamed asset loading (`Fx.assets`), entities (`Fx.entity`) and frame loops (`Fx.tick`). Use them instead of hand-written `while not HasModelLoaded() do Wait(0) end` loops, `playerDropped` bookkeeping and `GetConvar` parsing. Every function here returns an effect unless noted, so nothing happens until you run it (`Fx.yield` inside `Fx.gen`, `Fx.runFork`, `Fx.runAwait`); see [Effects](#effects).

All modules load lazily the first time you touch `Fx.<module>`. Scoped helpers (`use*`, `spawn*`, `StateKey:watch`, `Fx.nui.useFocus`) need a `Scope` service, which you get from `Fx.scoped`, a scoped layer, `Fx.player.extend` or `Fx.resourceScope:extend`; without one the effect dies with `Service not found: Scope`. See [Resources and scopes](#scopes-services-layers).

| Module | Side |
|---|---|
| `Fx.player` | server |
| `Fx.onStop`, `Fx.resourceScope` | both |
| `Fx.config` | both (client sees replicated convars only) |
| `Fx.assets`, `Fx.poll` | client |
| `Fx.entity` | both, except `requestControl` (client only) |
| `Fx.tick` | `everyFrame` and `whileTrue` both, `whileNear` client |

### Player scopes

`Fx.player` gives every connected player a [Scope](#scopes-services-layers) that closes when the player drops. Anything attached to it (fibers, finalizers, scoped resources) is released then. `Fx.net.handle` and `Fx.rpc.register` handler fibers on the server are attached to the sender's player scope automatically, so a drop interrupts them (see [Net and RPC](#net-events-and-rpc)).

#### Fx.player.scope(src)

```lua
Fx.player.scope(src: integer|string) -> Fx.ScopeObject
-- src: server id (converted with tonumber)
```

- **Side:** server.
- **Parameters:** `src`, the player's server id.
- **Returns:** the player's scope object, created on first use. Not an effect.
- **Fails with:** never.
- **Notes:**
  - The scope closes on `playerDropped` with an interrupt exit. The close runs on its own fiber, so finalizers may suspend (save to the database, call an RPC).
  - After a drop, the next call for the same id creates a fresh scope. Calling it for a player who has already left creates a scope that only closes when that id drops again or the resource stops.
  - The object has the scope methods `:addFinalizer(fin)`, `:close(exit)`, `:fork()` and `:extend(eff)` ([Resources and scopes](#scopes-services-layers)).
  - On the client nothing closes it except resource stop.

```lua
local s = Fx.player.scope(source)
Fx.runFork(s:addFinalizer(function()
  return Fx.logInfo('session ended', { player = source })
end))
```

#### Fx.player.extend(src, eff)

```lua
Fx.player.extend(src: integer, eff: Fx.Effect<A, E>) -> Fx.Effect<A, E>
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `eff`, an effect that may use `Scope`.
- **Returns:** `eff` with the player's scope provided as its `Scope` service.
- **Fails with:** whatever `eff` fails with.
- **Notes:** resources `eff` acquires (`Fx.acquireRelease`, `Fx.entity.spawnVehicle`, `StateKey:watch`) are released when the player drops, not when `eff` ends. `eff` itself is not interrupted by the drop; use `Fx.player.fork` for that.

```lua
-- a rental car that is deleted when the renter disconnects
Fx.rpc.register('rental:spawn', { input = S.struct {} }, function(src)
  local ped = GetPlayerPed(src)
  return Fx.player.extend(src, Fx.entity.spawnVehicle('faggio', GetEntityCoords(ped), GetEntityHeading(ped)))
    :map(function(veh) return NetworkGetNetworkIdFromEntity(veh) end)
end)
```

#### Fx.player.fork(src, eff, opts)

```lua
Fx.player.fork(src: integer, eff: Fx.Effect<any, any>, opts?: { onExit?: fun(exit: Fx.Exit), context?: table }) -> Fx.Fiber
-- opts: passed to Fx.runFork
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `eff`, the effect to run; `opts`, the same options as `Fx.runFork`.
- **Returns:** the running fiber (not an effect; it starts right away).
- **Fails with:** never itself. The fiber is interrupted when the player drops; if it ends on its own first, it is detached from the scope.
- **Notes:** the fiber does not get the player's scope as its `Scope` service. Combine with `Fx.player.extend` if it acquires resources.

```lua
AddEventHandler('playerJoining', function()
  local src = source
  Fx.player.fork(src, Fx.gen(function()
    while true do
      Fx.yield(Fx.sleep(60000))
      Fx.yield(Payroll.paySalary(src))
    end
  end))
end)
```

#### Fx.player.onDrop(src, fin)

```lua
Fx.player.onDrop(src: integer, fin: fun()|Fx.Effect<any, any>)
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `fin`, a plain function (called with no arguments) or an effect.
- **Returns:** nothing. Not an effect; the finalizer is registered immediately.
- **Fails with:** never. A finalizer that fails or raises is logged as a defect and the other finalizers still run.
- **Notes:** finalizers run last added first. They also run if the resource stops while the player is online, and then they must be synchronous (see [What closes on resource stop](#what-closes-on-resource-stop)).

```lua
Fx.player.onDrop(src, Fx.db.update('UPDATE players SET last_seen = NOW() WHERE id = ?', { charId }))
Fx.player.onDrop(src, function() activeJobs[src] = nil end)
```

### Resource lifecycle

#### Fx.onStop(fin)

```lua
Fx.onStop(fin: fun()|Fx.Effect<any, any>)
```

- **Side:** both.
- **Parameters:** `fin`, a plain function (called with no arguments) or an effect.
- **Returns:** nothing. Not an effect; the finalizer is added to `Fx.resourceScope` right away.
- **Fails with:** never. A finalizer that fails is reported as `scope finalizer on stop` and the rest still run.
- **Notes:** runs when this resource stops. The stop handler has no later tick, so the finalizer must finish synchronously: an effect that sleeps, waits on a fiber or makes an async call (`Fx.db.*`, `Fx.rpc.call`) fails with `Fx.runSync hit an async effect` and is skipped.

```lua
Fx.onStop(function()
  for _, blip in pairs(shopBlips) do RemoveBlip(blip) end
end)
```

#### Fx.resourceScope

```lua
---@type Fx.ScopeObject
Fx.resourceScope
```

- **Side:** both.
- **Returns:** the scope of this resource, created when `init.lua` loads. A value, not a function.
- **Fails with:** never.
- **Notes:** closes when the resource stops. Use `Fx.resourceScope:extend(eff)` to tie scoped resources to the resource's lifetime, or `Fx.resourceScope:fork()` for a child scope you can close earlier.

```lua
-- client: the shop ped exists for as long as the resource runs
Fx.runFork(Fx.resourceScope:extend(
  Fx.entity.spawnPed('s_m_m_shopkeep_01', vector3(24.5, -1346.6, 28.5), 270.0, { networked = false })))
```

#### What closes on resource stop

When `onResourceStop` fires for this resource, Rivo FX:

1. Interrupts every root fiber (fibers started with `Fx.runFork`, `Fx.runAwait`, and so on).
2. Closes every open scope, newest first, synchronously, with an interrupt exit. That includes `Fx.scoped` scopes inside running fibers, runtime layer scopes (`Fx.Runtime.make`, `Fx.Layer.scoped`), player scopes and `Fx.resourceScope` (one of the oldest, so it closes near the end).

So on stop, scoped models and dictionaries are released, scoped entities are deleted, `StateKey:watch` handlers are removed, NUI focus taken with `Fx.nui.useFocus` is released, and `Fx.onStop` / `Fx.player.onDrop` finalizers run. Finalizers that need to wait are reported and skipped. The e2e suite checks that a scoped finalizer, a scoped layer's finalizer and an `Fx.onStop` function all run on stop.

### Configuration

`Fx.config` reads convars and config files into typed values. Every reader is an effect that fails with `ConfigError` instead of handing you a `nil` or a string you forgot to convert.

`Fx.config.ConfigError` is the error class. Fields: `name` (the convar name or file path) and `message`. See [Errors](#errors-and-gotchas).

All convar readers share these rules:

- A convar that is unset or set to `""` is missing. Missing with a default succeeds with the default (returned as given, not parsed or checked). Missing without a default fails with `ConfigError { message = 'convar <name> is not set' }`.
- A value that does not parse fails with `ConfigError { message = 'convar <name>: expected <kind>, got "<raw>"' }`.
- They read `GetConvar`, which on the client only sees replicated convars (`setr`).
- They read the convar each time the effect runs, so re-running picks up a changed value.

#### Fx.config.string(name, default)

```lua
Fx.config.string(name: string, default?: string) -> Fx.Effect<string, ConfigError>
```

- **Side:** both.
- **Parameters:** `name`, the convar; `default`, used when it is missing.
- **Returns:** the raw string.
- **Fails with:** `ConfigError` when missing without a default.

```lua
local webhook = Fx.yield(Fx.config.string('garage:webhook'))
```

#### Fx.config.number(name, default)

```lua
Fx.config.number(name: string, default?: number) -> Fx.Effect<number, ConfigError>
```

- **Side:** both.
- **Returns:** the value parsed with `tonumber`.
- **Fails with:** `ConfigError` when missing without a default, or when it is not a number (NaN is refused).

```lua
local tax = Fx.yield(Fx.config.number('shop:taxRate', 0.08))
```

#### Fx.config.int(name, default)

```lua
Fx.config.int(name: string, default?: integer) -> Fx.Effect<integer, ConfigError>
```

- **Side:** both.
- **Returns:** an integer. `"7"` and `"7.0"` both give `7`.
- **Fails with:** `ConfigError` when missing without a default, or when the value is not an integer (`"abc"`, `"7.5"`). Message example: `convar garage:maxCars: expected integer, got "abc"`.

```lua
local maxCars = Fx.yield(Fx.config.int('garage:maxCars', 5))
```

#### Fx.config.bool(name, default)

```lua
Fx.config.bool(name: string, default?: boolean) -> Fx.Effect<boolean, ConfigError>
```

- **Side:** both.
- **Returns:** `true` for `true`, `1`, `yes`, `on`; `false` for `false`, `0`, `no`, `off`. Case-insensitive.
- **Fails with:** `ConfigError` when missing without a default, or for any other value.
- **Notes:** a default of `false` works (only `nil` means "no default").

```lua
local debug = Fx.yield(Fx.config.bool('garage:debug', false))
```

#### Fx.config.enum(name, values, default)

```lua
Fx.config.enum(name: string, values: string[], default?: string) -> Fx.Effect<string, ConfigError>
```

- **Side:** both.
- **Parameters:** `values`, the allowed strings.
- **Returns:** the convar's value, which is one of `values`.
- **Fails with:** `ConfigError` when missing without a default, or when the value is not in `values` (`expected one of a, b, c`). The match is case-sensitive.

```lua
local mode = Fx.yield(Fx.config.enum('garage:parking', { 'public', 'private', 'off' }, 'public'))
```

#### Fx.config.json(name, schema, default)

```lua
Fx.config.json(name: string, schema: Fx.Schema, default?: any) -> Fx.Effect<any, ConfigError>
```

- **Side:** both.
- **Parameters:** `schema`, checked against the decoded JSON ([Schema](#schema)).
- **Returns:** the value as the schema outputs it (unknown struct keys stripped, transforms applied).
- **Fails with:** `ConfigError` when missing without a default, when the JSON does not decode, decodes to `null`, or fails the schema. The message is `expected JSON matching the schema, got "<raw>"`; the schema's own message is not included.

```lua
local Spots = S.array(S.struct { x = S.number, y = S.number, z = S.number })
local spots = Fx.yield(Fx.config.json('garage:spots', Spots, {}))
```

```cfg
set garage:spots '[{"x":215.8,"y":-810.1,"z":30.7}]'
```

#### Fx.config.struct(fields)

```lua
Fx.config.struct(fields: table<string, Fx.Effect<any, any>>) -> Fx.Effect<table, ConfigError>
```

- **Side:** both.
- **Parameters:** `fields`, a table of name to config effect (any effects work).
- **Returns:** a table with the same keys and the read values.
- **Fails with:** the first `ConfigError`. Fields are read one after another in `pairs` order and reading stops at the first failure, so only one problem is reported per run (the source comment says all are reported; the code does not do that).
- **Notes:** this is `Fx.all(fields)`.

```lua
local Config = Fx.config.struct {
  maxCars = Fx.config.int('garage:maxCars', 5),
  webhook = Fx.config.string('garage:webhook'),
  debug = Fx.config.bool('garage:debug', false),
}

Fx.runFork(Fx.gen(function()
  local cfg = Fx.yield(Config)
  print(('garage: up to %d cars'):format(cfg.maxCars))
end))
```

#### Fx.config.file(path, schema, opts)

```lua
Fx.config.file(path: string, schema: Fx.Schema, opts?: { resource?: string }) -> Fx.Effect<any, ConfigError>
-- path: path inside the resource, e.g. 'config.json' or 'config/shops.lua'
-- opts.resource: defaults to the current resource
```

- **Side:** both (the file must be loadable with `LoadResourceFile` on that side, so list it in `files` for the client).
- **Parameters:** `path`; `schema`, checked against the loaded data; `opts.resource`, the resource to read from.
- **Returns:** the data as the schema outputs it.
- **Fails with:** `ConfigError { name = path }` with message `<res>/<path> not found`, `invalid JSON`, the Lua load or runtime error, or the schema's message.
- **Notes:**
  - A path ending in `.json` is decoded as JSON. Any other path is loaded as Lua text that must `return` a table.
  - Lua config files run with an empty environment: no globals (`vector3`, `print`, `GetConvar`) are available. Use plain tables and numbers.

```lua
-- config/shops.lua
return {
  { name = 'Ammu-Nation', x = 22.0, y = -1107.2, z = 29.8 },
}
```

```lua
local Shops = S.array(S.struct { name = S.string, x = S.number, y = S.number, z = S.number })
local shops = Fx.yield(Fx.config.file('config/shops.lua', Shops))
```

### Assets

`Fx.assets` loads streamed assets with a timeout and typed errors. Each loader has a scoped `use*` twin that releases the asset when the current scope closes.

Shared rules:

- `opts.timeout` is in milliseconds, default `10000`.
- The asset is polled once per frame until it loads.
- `AssetTimeout { kind, name, timeoutMs }` when it does not load in time. `name` is what you passed.
- `AssetNotFound { kind, name }` is only checked for models (`IsModelInCdimage` and `IsModelValid`) and anim dictionaries (`DoesAnimDictExist`). A wrong name for any other kind ends in `AssetTimeout`.
- `use*` variants need a `Scope`. They release the asset (`SetModelAsNoLongerNeeded`, `RemoveAnimDict`, ...) when the scope closes. The plain loaders never release.
- `kind` is one of `model`, `animDict`, `animSet`, `ptfx`, `textureDict`, `scaleform`, `audioBank`.

The error classes are `Fx.assets.AssetNotFound` and `Fx.assets.AssetTimeout`. See [Errors](#errors-and-gotchas).

#### Fx.assets.model(model, opts)

```lua
Fx.assets.model(model: string|integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetNotFound|AssetTimeout>
-- model: name or hash
```

- **Side:** client.
- **Parameters:** `model`, a name (hashed with `joaat`) or a hash; `opts.timeout`.
- **Returns:** the model hash.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** you release it yourself with `SetModelAsNoLongerNeeded`, or use `useModel`.

```lua
CreateThread(function()
  local ok, hash = pcall(Fx.runAwait, Fx.assets.model('adder', { timeout = 5000 }))
  if not ok then return print('could not load adder: ' .. tostring(hash._tag)) end
  local veh = CreateVehicle(hash, 215.8, -810.1, 30.7, 0.0, true, false)
  SetModelAsNoLongerNeeded(hash)
end)
```

#### Fx.assets.useModel(model, opts)

```lua
Fx.assets.useModel(model: string|integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the model hash.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** calls `SetModelAsNoLongerNeeded` when the scope closes.

```lua
Fx.runFork(Fx.scoped(Fx.gen(function()
  local hash = Fx.yield(Fx.assets.useModel('prop_tool_box_04'))
  local obj = CreateObject(hash, 0.0, 0.0, 72.0, false, false, false)
  -- ...
end)))
```

#### Fx.assets.animDict(dict, opts)

```lua
Fx.assets.animDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetNotFound|AssetTimeout>
```

- **Side:** client.
- **Returns:** the dictionary name.
- **Fails with:** `AssetNotFound` (when `DoesAnimDictExist` is false), `AssetTimeout`.

```lua
local dict = Fx.yield(Fx.assets.animDict('mini@repair'))
TaskPlayAnim(PlayerPedId(), dict, 'fixing_a_ped', 8.0, -8.0, -1, 1, 0, false, false, false)
```

#### Fx.assets.useAnimDict(dict, opts)

```lua
Fx.assets.useAnimDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the dictionary name.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** calls `RemoveAnimDict` when the scope closes.

```lua
local repair = Fx.scoped(Fx.gen(function()
  local dict = Fx.yield(Fx.assets.useAnimDict('mini@repair'))
  TaskPlayAnim(PlayerPedId(), dict, 'fixing_a_ped', 8.0, -8.0, 5000, 1, 0, false, false, false)
  Fx.yield(Fx.sleep(5000))
end))
```

#### Fx.assets.animSet(set, opts)

```lua
Fx.assets.animSet(set: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the anim set name.
- **Fails with:** `AssetTimeout` (no existence check).

```lua
local set = Fx.yield(Fx.assets.animSet('move_m@drunk@verydrunk'))
SetPedMovementClipset(PlayerPedId(), set, 0.2)
```

#### Fx.assets.useAnimSet(set, opts)

```lua
Fx.assets.useAnimSet(set: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the anim set name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `RemoveAnimSet` when the scope closes.

```lua
Fx.yield(Fx.assets.useAnimSet('move_m@injured'))
```

#### Fx.assets.ptfx(asset, opts)

```lua
Fx.assets.ptfx(asset: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the particle asset name (`RequestNamedPtfxAsset` / `HasNamedPtfxAssetLoaded`).
- **Fails with:** `AssetTimeout`.

```lua
local fx = Fx.yield(Fx.assets.ptfx('core'))
UseParticleFxAsset(fx)
StartParticleFxNonLoopedAtCoord('ent_sht_electrical_box', x, y, z, 0.0, 0.0, 0.0, 1.0, false, false, false)
```

#### Fx.assets.usePtfx(asset, opts)

```lua
Fx.assets.usePtfx(asset: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the particle asset name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `RemoveNamedPtfxAsset` when the scope closes.

```lua
Fx.yield(Fx.assets.usePtfx('scr_rcbarry2'))
```

#### Fx.assets.textureDict(dict, opts)

```lua
Fx.assets.textureDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the texture dictionary name (`RequestStreamedTextureDict(dict, false)`).
- **Fails with:** `AssetTimeout`.

```lua
local txd = Fx.yield(Fx.assets.textureDict('commonmenu'))
DrawSprite(txd, 'shop_box_tick', 0.5, 0.5, 0.02, 0.03, 0.0, 255, 255, 255, 255)
```

#### Fx.assets.useTextureDict(dict, opts)

```lua
Fx.assets.useTextureDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the texture dictionary name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `SetStreamedTextureDictAsNoLongerNeeded` when the scope closes.

```lua
Fx.yield(Fx.assets.useTextureDict('mpinventory'))
```

#### Fx.assets.scaleform(name, opts)

```lua
Fx.assets.scaleform(name: string, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetTimeout>
```

- **Side:** client.
- **Returns:** the scaleform handle from `RequestScaleformMovie` (not the name).
- **Fails with:** `AssetTimeout`.

```lua
local sf = Fx.yield(Fx.assets.scaleform('MP_BIG_MESSAGE_FREEMODE'))
BeginScaleformMovieMethod(sf, 'SHOW_SHARD_WASTED_MP_MESSAGE')
```

#### Fx.assets.useScaleform(name, opts)

```lua
Fx.assets.useScaleform(name: string, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the scaleform handle.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `SetScaleformMovieAsNoLongerNeeded(handle)` when the scope closes.

```lua
-- show a banner for 5 seconds; the draw loop stops and the movie is released when the scope closes
Fx.runFork(Fx.scoped(Fx.gen(function()
  local sf = Fx.yield(Fx.assets.useScaleform('MP_BIG_MESSAGE_FREEMODE'))
  BeginScaleformMovieMethod(sf, 'SHOW_SHARD_CENTERED_MP_MESSAGE')
  ScaleformMovieMethodAddParamTextureNameString('DELIVERED')
  EndScaleformMovieMethod()
  Fx.yield(Fx.tick.everyFrame(function() DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0) end):forkScoped())
  Fx.yield(Fx.sleep(5000))
end)))
```

#### Fx.assets.audioBank(bank, opts)

```lua
Fx.assets.audioBank(bank: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the bank name.
- **Fails with:** `AssetTimeout`.
- **Notes:** loading calls `RequestScriptAudioBank(bank, false)` every frame until it returns true.

```lua
Fx.yield(Fx.assets.audioBank('DLC_HEIST_HACKING_SNAKE'))
```

#### Fx.assets.useAudioBank(bank, opts)

```lua
Fx.assets.useAudioBank(bank: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the bank name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `ReleaseNamedScriptAudioBank` when the scope closes.

```lua
Fx.yield(Fx.assets.useAudioBank('DLC_HEIST_HACKING_SNAKE'))
```

#### Fx.poll(check, timeout, onTimeout)

```lua
Fx.poll(check: fun(): boolean, timeout: integer, onTimeout: fun(): any) -> Fx.Effect<nil, any>
-- timeout: ms
-- onTimeout: builds the error
```

- **Side:** client (defined by the assets module).
- **Parameters:** `check`, called once per frame; `timeout`; `onTimeout`, returns the error to fail with.
- **Returns:** `nil` once `check()` returns true.
- **Fails with:** whatever `onTimeout()` returns.
- **Notes:** `Fx.poll` is created when `Fx.assets` loads. Before anything touches `Fx.assets`, `Fx.poll` is `nil` (the type file declares it unconditionally). Touch `Fx.assets` first, for example `local _ = Fx.assets`.

```lua
local DoorTimeout = Fx.TaggedError('DoorTimeout')
local _ = Fx.assets
local waitForDoor = Fx.poll(function() return DoesObjectOfTypeExistAtCoords(x, y, z, 1.0, doorHash, false) end,
  3000, function() return DoorTimeout { door = 'pacific_vault' } end)
```

### Entities

`Fx.entity` checks entities, waits for network ids and control, and spawns entities that are deleted when their scope closes.

Error classes: `EntityGone { entity }`, `ControlTimeout { entity, timeoutMs }`, `NetIdTimeout { netId, timeoutMs }`, `SpawnFailed { kind, model }` (`kind` is `vehicle`, `ped` or `object`). All on `Fx.entity`. The default timeout everywhere is `5000` ms.

#### Fx.entity.exists(ent)

```lua
Fx.entity.exists(ent: integer) -> Fx.Effect<integer, EntityGone>
```

- **Side:** both.
- **Returns:** `ent` when it is not `nil`, not `0` and `DoesEntityExist(ent)`.
- **Fails with:** `EntityGone { entity = ent }`.

```lua
local veh = Fx.yield(Fx.entity.exists(GetVehiclePedIsIn(PlayerPedId(), false)))
```

#### Fx.entity.delete(ent)

```lua
Fx.entity.delete(ent: integer) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`. Does nothing if the entity is already gone.
- **Fails with:** never.
- **Notes:** on the client it calls `SetEntityAsMissionEntity(ent, true, true)` before `DeleteEntity`. This is the release used by the scoped spawns.

```lua
Fx.yield(Fx.entity.delete(oldVehicle))
```

#### Fx.entity.fromNetId(netId, opts)

```lua
Fx.entity.fromNetId(netId: integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, NetIdTimeout>
```

- **Side:** both, with different checks.
- **Returns:** the entity handle.
- **Fails with:** `NetIdTimeout { netId, timeoutMs }` when it does not appear in time.
- **Notes:** server polls `NetworkGetEntityFromNetworkId` plus `DoesEntityExist`. Client polls `NetworkDoesNetworkIdExist`, then returns `NetToEnt(netId)`. Polled once per frame.

```lua
-- client: the server sent a net id for a vehicle that may not have streamed in yet
Fx.net.handle('garage:spawned', S.struct { netId = S.int }, function(input)
  return Fx.entity.fromNetId(input.netId, { timeout = 3000 }):flatMap(function(veh)
    return Fx.sync(function() SetPedIntoVehicle(PlayerPedId(), veh, -1) end)
  end)
end)
```

#### Fx.entity.requestControl(ent, opts)

```lua
Fx.entity.requestControl(ent: integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, EntityGone|ControlTimeout>
```

- **Side:** client only. On the server `Fx.entity.requestControl` is `nil` (the type file does not say so).
- **Returns:** `ent` once `NetworkHasControlOfEntity(ent)` is true.
- **Fails with:** `EntityGone` when the entity does not exist at the start; `ControlTimeout { entity, timeoutMs }`.
- **Notes:** calls `NetworkRequestControlOfEntity` every frame until it has control.

```lua
local veh = Fx.yield(Fx.entity.requestControl(target, { timeout = 2000 }))
SetVehicleDoorsLocked(veh, 2)
```

#### Fx.entity.spawnVehicle(model, coords, heading, opts)

```lua
Fx.entity.spawnVehicle(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: { networked?: boolean, timeout?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- coords: vector3 works
-- heading: default 0.0
-- requires Scope
```

- **Side:** both.
- **Parameters:** `opts.networked` defaults to `true`; `opts.timeout` (default `5000`) applies to the model load and, separately, to the wait for the entity to exist.
- **Returns:** the vehicle handle.
- **Fails with:** `SpawnFailed { kind = 'vehicle', model }` when the entity does not exist in time; on the client also `AssetNotFound` / `AssetTimeout` from loading the model.
- **Notes:**
  - Deleted with `Fx.entity.delete` when the current scope closes.
  - Client: loads the model with `Fx.assets.model`, calls `CreateVehicle(hash, x, y, z, heading, networked, true)`, then `SetModelAsNoLongerNeeded`.
  - Server: calls `CreateVehicle` directly with the same arguments; no model load.

```lua
-- client: a test drive that ends after 60 seconds, wherever it ends
Fx.runFork(Fx.scoped(Fx.gen(function()
  local veh = Fx.yield(Fx.entity.spawnVehicle('sultan', vector3(-56.8, -1109.1, 26.4), 70.0))
  SetPedIntoVehicle(PlayerPedId(), veh, -1)
  Fx.yield(Fx.sleep(60000))
end)))
```

#### Fx.entity.spawnPed(model, coords, heading, opts)

```lua
Fx.entity.spawnPed(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: { networked?: boolean, timeout?: integer, pedType?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- heading: default 0.0
-- requires Scope
```

- **Side:** both.
- **Parameters:** as `spawnVehicle`, plus `opts.pedType` (default `4`).
- **Returns:** the ped handle.
- **Fails with:** `SpawnFailed { kind = 'ped', model }`; on the client also `AssetNotFound` / `AssetTimeout`.
- **Notes:** calls `CreatePed(pedType, hash, x, y, z, heading, networked, true)`. Deleted when the scope closes.

```lua
Fx.yield(Fx.entity.spawnPed('s_m_y_cop_01', vector3(441.0, -982.0, 30.7), 90.0, { networked = false }))
```

#### Fx.entity.spawnObject(model, coords, opts)

```lua
Fx.entity.spawnObject(model: string|integer, coords: { x: number, y: number, z: number }, opts?: { networked?: boolean, timeout?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** both.
- **Parameters:** no heading; `opts` as `spawnVehicle`.
- **Returns:** the object handle.
- **Fails with:** `SpawnFailed { kind = 'object', model }`; on the client also `AssetNotFound` / `AssetTimeout`.
- **Notes:** calls `CreateObject(hash, x, y, z, networked, true, false)`. Deleted when the scope closes.

```lua
local cone = Fx.yield(Fx.entity.spawnObject('prop_roadcone02a', vector3(410.2, -1000.5, 28.3)))
PlaceObjectOnGroundProperly(cone)
```

### Frame loops

`Fx.tick` runs a function every frame on one plain Citizen thread, and stops when the fiber running the effect is interrupted or its scope closes. The effects never succeed; they run until stopped. If the function (or the condition) raises, the effect dies with that error as a defect. Run them with `Fx.runFork` and keep the fiber, or with `:forkScoped()` inside a scope. See [Concurrency](#concurrency).

#### Fx.tick.everyFrame(fn)

```lua
Fx.tick.everyFrame(fn: fun()) -> Fx.Effect<never, never>
```

- **Side:** both (on the server a frame is a server tick).
- **Parameters:** `fn`, called once per frame (`Wait(0)` between calls).
- **Returns:** never succeeds.
- **Fails with:** dies with the error `fn` raises.

```lua
local hud = Fx.runFork(Fx.tick.everyFrame(function()
  HideHudComponentThisFrame(14) -- crosshair
end))
-- later
hud:interruptAsFork(0)
```

#### Fx.tick.whileNear(coords, radius, fn, opts)

```lua
Fx.tick.whileNear(coords: { x: number, y: number, z: number }, radius: number, fn: fun(distance: number), opts?: { checkMs?: integer }) -> Fx.Effect<never, never>
-- coords: vector3 works; read once
-- opts.checkMs: default 500
```

- **Side:** client (uses `PlayerPedId()`).
- **Parameters:** `fn` gets the distance from the local ped to `coords`; `opts.checkMs`, how often the distance is checked while out of range.
- **Returns:** never succeeds.
- **Fails with:** dies with the error `fn` raises.
- **Notes:** within `radius`, `fn` runs every frame. Outside it, the thread sleeps `checkMs` between distance checks, so being far away costs almost nothing.

```lua
local shop = vector3(25.7, -1347.3, 29.5)
Fx.runFork(Fx.tick.whileNear(shop, 10.0, function(d)
  DrawMarker(1, shop.x, shop.y, shop.z - 1.0, 0, 0, 0, 0, 0, 0, 1.5, 1.5, 0.5, 0, 150, 255, 120, false, false, 2, false, nil, nil, false)
  if d < 1.5 and IsControlJustPressed(0, 38) then TriggerEvent('shop:open') end
end))
```

#### Fx.tick.whileTrue(condition, fn, opts)

```lua
Fx.tick.whileTrue(condition: fun(): boolean, fn: fun(), opts?: { checkMs?: integer }) -> Fx.Effect<never, never>
-- opts.checkMs: default 250
```

- **Side:** both.
- **Parameters:** `condition`, checked every frame while true and every `checkMs` while false; `fn`, run every frame while `condition()` is true.
- **Returns:** never succeeds.
- **Fails with:** dies with the error `condition` or `fn` raises.

```lua
-- client: show the speedometer only while driving
Fx.runFork(Fx.tick.whileTrue(function() return IsPedInAnyVehicle(PlayerPedId(), false) end, function()
  local kmh = GetEntitySpeed(GetVehiclePedIsIn(PlayerPedId(), false)) * 3.6
  Hud.drawSpeed(kmh)
end))
```

<a id="kvp-state-database-frameworks"></a>

## KVP, state bags, database, frameworks
This page covers the modules that store and read data: resource KVP (`Fx.kvp`), state bags (`Fx.state`), oxmysql (`Fx.db`) and the player, money and job API over ESX, QBCore, Qbox and standalone (`Fx.framework`). Each one checks values with a [Schema](#schema) at the boundary and turns failures into tagged errors you can catch with `catchTag` ([Errors](#errors-and-causes)). Every function returns an effect unless noted; run it with `Fx.yield` inside `Fx.gen`, `Fx.runFork` or `Fx.runAwait` ([Effects](#effects)).

| Module | Side |
|---|---|
| `Fx.kvp` | both |
| `Fx.state` | both |
| `Fx.db` | server |
| `Fx.framework` | server |

### KVP

`Fx.kvp` stores values in the resource's KVP (`SetResourceKvp`) as JSON. With a schema, values are checked on the way in and on the way out.

Error classes on `Fx.kvp`:

- `KvpInvalid { key, message }`: a write was refused (failed its schema, cannot be encoded, or would not survive JSON).
- `KvpDecodeError { key, message }`: a stored value is not valid JSON or fails its schema.

#### Fx.kvp.get(key, schema)

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

#### Fx.kvp.set(key, value, schema)

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

#### Fx.kvp.delete(key)

```lua
Fx.kvp.delete(key: string) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** never.

```lua
Fx.yield(Fx.kvp.delete('radio:prefs'))
```

#### Fx.kvp.keys(prefix)

```lua
Fx.kvp.keys(prefix: string) -> Fx.Effect<string[], never>
```

- **Side:** both.
- **Returns:** every key starting with `prefix` (full keys, prefix included), sorted. An empty list when there are none.
- **Fails with:** never.

```lua
local keys = Fx.yield(Fx.kvp.keys('garage:'))   -- { 'garage:ABC123', 'garage:XYZ789' }
```

#### Fx.kvp.typed(prefix, schema)

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

#### KvpTyped:get(id)

```lua
KvpTyped:get(id: string) -> Fx.Effect<any, KvpDecodeError>
```

- **Side:** both.
- **Returns:** the value at `prefix .. id`, or `nil` when unset.
- **Fails with:** `KvpDecodeError`.

```lua
local car = Fx.yield(Garage:get('ABC123'))
```

#### KvpTyped:set(id, value)

```lua
KvpTyped:set(id: string, value: any) -> Fx.Effect<nil, KvpInvalid>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** `KvpInvalid` (same rules as `Fx.kvp.set`).

```lua
Fx.yield(Garage:set('ABC123', { model = 'sultan', fuel = 64 }))
```

#### KvpTyped:delete(id)

```lua
KvpTyped:delete(id: string) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`.
- **Fails with:** never.

```lua
Fx.yield(Garage:delete('ABC123'))
```

#### KvpTyped:ids()

```lua
KvpTyped:ids() -> Fx.Effect<string[], never>
```

- **Side:** both.
- **Returns:** every stored id under the prefix, without the prefix, sorted.
- **Fails with:** never.

```lua
local plates = Fx.yield(Garage:ids())   -- { 'ABC123', 'XYZ789' }
```

#### KvpTyped:all()

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

### State bags

`Fx.state` puts a schema on a state bag key. Values are checked when you set them and when a change arrives, so a handler never sees a value that fails the schema. On the server, an invalid value a client wrote to its own player or entity bag is dropped and reported as an `invalid_state` security event ([Net and RPC](#net-events-and-rpc)).

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

#### Fx.state.key(name, schema)

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

#### Fx.state.global()

```lua
Fx.state.global() -> Fx.StateBag
```

- **Side:** both.
- **Returns:** the `GlobalState` bag, named `global`. Not an effect.

```lua
local Weather = Fx.state.key('weather', S.literal('CLEAR', 'RAIN', 'THUNDER'))
Fx.yield(Weather:set(Fx.state.global(), 'RAIN'))
```

#### Fx.state.player(src)

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

#### Fx.state.entity(ent)

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

#### StateKey:get(bag)

```lua
StateKey:get(bag: Fx.StateBag) -> Fx.Effect<any, StateInvalid>
```

- **Side:** both.
- **Returns:** the current value as the schema outputs it, or `nil` when unset.
- **Fails with:** `StateInvalid` when the bag holds a value that fails the schema.

```lua
local job = Fx.yield(Job:get(Fx.state.player()))   -- client, local player
```

#### StateKey:set(bag, value, opts)

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

#### StateKey:clear(bag, opts)

```lua
StateKey:clear(bag: Fx.StateBag, opts?: { replicated?: boolean }) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`. Same as `StateKey:set(bag, nil, opts)`.
- **Fails with:** never in practice (`nil` passes the check).

```lua
Fx.yield(Job:clear(Fx.state.player(src)))
```

#### StateKey:onChange(handler, opts)

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

#### StateKey:watch(handler, opts)

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

#### StateKey:await(bag, predicate, opts)

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

#### StateKey:changes(opts)

```lua
StateKey:changes(opts?: { bag?: Fx.StateBag|string, buffer?: integer, strategy?: 'sliding'|'dropping' }) -> Fx.Stream<Fx.StateChange>
```

- **Side:** both.
- **Parameters:** `opts.bag` as in `onChange`; `opts.buffer` (default 1024) and `opts.strategy` (default `sliding`, drops the oldest; `dropping` keeps the oldest) as in `Fx.Stream.async`.
- **Returns:** a [stream](#streams) of valid change records. The handler is registered while the stream runs and removed when it ends.
- **Fails with:** never.

```lua
-- client: react to job changes, but not to every flicker
Fx.runFork(Job:changes({ bag = Fx.state.player() })
  :debounce(250)
  :runForEach(function(change) return Hud.setJob(change.value) end))
```

### Database

`Fx.db` runs oxmysql queries as effects. Every failure is a `SqlError`, and a row that fails its schema is a `SqlDecodeError`, so you can catch, retry or map them. Queries go to oxmysql unless an `Fx.db.Database` service is provided.

Error classes on `Fx.db`:

- `SqlError { method, sql, message }`: the driver reported an error. For `transaction`, `sql` is absent. `message` is the database's line: FiveM's "An error occurred while calling export" wrapping and oxmysql's query dump are stripped, as are `^1`-style colour codes.
- `SqlDecodeError { sql, index, message }`: row `index` (1-based) failed `opts.row`, or the scalar failed `opts.value` (`index` is 1).

#### Fx.db.query(sql, params, opts)

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

#### Fx.db.single(sql, params, opts)

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

#### Fx.db.scalar(sql, params, opts)

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

#### Fx.db.insert(sql, params)

```lua
Fx.db.insert(sql: string, params?: table) -> Fx.Effect<integer, SqlError>
```

- **Side:** server.
- **Returns:** the new row's id.
- **Fails with:** `SqlError`.

```lua
local id = Fx.yield(Fx.db.insert('INSERT INTO bank_logs (cid, amount, reason) VALUES (?, ?, ?)', { cid, 500, 'garage fee' }))
```

#### Fx.db.update(sql, params)

```lua
Fx.db.update(sql: string, params?: table) -> Fx.Effect<integer, SqlError>
```

- **Side:** server.
- **Returns:** the number of affected rows.
- **Fails with:** `SqlError`.

```lua
local n = Fx.yield(Fx.db.update('UPDATE owned_vehicles SET garage = ? WHERE plate = ?', { 'pillbox', plate }))
```

#### Fx.db.prepare(sql, params)

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

#### Fx.db.transaction(queries, params)

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

#### Fx.db.Database

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

### Framework

`Fx.framework` gives one player, money and job API over ESX, QBCore, Qbox and standalone. You get it as the `Framework` service from a layer and read it with `Fx.yield(Fx.framework.Framework)` ([Services and layers](#scopes-services-layers)).

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

#### Fx.framework.auto

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

#### Fx.framework.esx, qbcore, qbox, standalone

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

#### Fx.framework.detect()

```lua
Fx.framework.detect() -> 'qbox'|'qbcore'|'esx'|'standalone'
```

- **Side:** server.
- **Returns:** the first started resource among `qbx_core` (qbox), `qb-core` (qbcore), `es_extended` (esx); else `standalone`. Not an effect.
- **Notes:** Qbox is checked before QBCore.

```lua
print('framework: ' .. Fx.framework.detect())
```

#### Fx.framework.Framework

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

#### fw.getPlayer(src)

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

#### fw.findPlayer(src)

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

#### fw.getMoney(src, account)

```lua
fw.getMoney(src: integer, account: 'cash'|'bank') -> Fx.Effect<number, PlayerNotFound|FrameworkError>
```

- **Side:** server.
- **Returns:** the live balance (read from the framework each time, not from a copy).
- **Fails with:** `FrameworkError` for any account other than `cash` or `bank`; `PlayerNotFound`.

```lua
local cash = Fx.yield(fw.getMoney(src, 'cash'))
```

#### fw.addMoney(src, account, amount, reason)

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

#### fw.removeMoney(src, account, amount, reason)

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

#### fw.setJob(src, job, grade)

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

#### fw.onPlayerLoaded(fn)

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

#### fw.onPlayerUnloaded(fn)

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

#### fw.onJobChange(fn)

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

<a id="nui"></a>

## NUI
This page covers typed NUI: the Lua side `Fx.nui` in a client script, and the page side `@rivolabs/fx-nui`, a dependency-free TypeScript package for the browser page (React, Svelte, Vue or plain JS). Together they replace raw `RegisterNUICallback` / `SendNUIMessage` / `fetch`: page calls are checked against a [Schema](#schema), answers carry either a value or a tagged error, and the page can branch on the error's tag the way Lua code uses `catchTag`. It also covers running the page in a normal browser while you build it.

### Wire format

A callback registered with `Fx.nui.handle` always answers with one of:

```ts
{ ok: true, value: unknown }
{ ok: false, error: { _tag: string, ...fields } }
```

| `_tag` | When | Fields |
|---|---|---|
| `NuiInvalidInput` | the body failed `spec.input` | `name`, `message` (the schema's message) |
| your tag (`OutOfStock`, `InsufficientFunds`, ...) | the handler failed with a tagged error, including one from `Fx.rpc.call` | the error's fields, serialized with `Fx.serializeError` (functions dropped) |
| `NuiInternalError` | the handler raised, died, failed with something that is not a tagged error, or returned a value that failed `spec.output` | `name` only. The cause is logged in the client console with `Fx.log.error`, never sent to the page |
| `NuiInterrupted` | the handler's fiber was interrupted (for example on resource stop) | `name` |

The page side adds two tags of its own: `NuiTimeout` and `NuiTransportError` (see [fetchNui](#fetchnuiname-input-options)).

Messages from `Fx.nui.send` arrive in the page as a window `message` event whose `data` is `{ type, payload }`.

### Lua side: Fx.nui

All of `Fx.nui` is client-side. Error classes on `Fx.nui`: `NuiInvalidInput` and `NuiInvalidMessage`. `NuiInternalError` and `NuiInterrupted` exist only as tags in callback answers; there are no classes for them. See [Errors](#errors-and-gotchas).

#### Fx.nui.handle(name, spec, handler)

```lua
Fx.nui.handle(name: string, spec: { input: Fx.Schema, output?: Fx.Schema }, handler: fun(input: any): any)
-- name: the callback name the page fetches
-- handler: returns a value or an effect
```

- **Side:** client.
- **Parameters:**
  - `name`: registered with `RegisterNUICallback(name, ...)`; the page calls `fetchNui(name, body)`.
  - `spec.input`: required. Checked against the request body; the handler gets the schema's output (unknown struct keys stripped).
  - `spec.output`: optional. Checked against the handler's result before it is sent.
  - `handler(input)`: returns a plain value or an effect.
- **Returns:** nothing. Not an effect; the callback is registered right away.
- **Fails with:** raises a Lua error at call time when `spec.input` is missing. At request time it never raises; every outcome becomes an answer (see [Wire format](#wire-format)).
- **Notes:**
  - Each request runs on its own fiber, so the handler can suspend (`Fx.rpc.call`, `Fx.sleep`) and `cb` is called when it ends. The page's fetch is never left hanging, even when the fiber is interrupted.
  - The handler's fiber has no `Scope` service. Wrap scoped work in `Fx.scoped`.
  - An `output` mismatch is treated as a bug in your code: the page gets `NuiInternalError` and the message `nui callback "<name>" returned invalid output: ...` is logged.

```lua
local S = Fx.S
local OutOfStock = Fx.TaggedError('OutOfStock')

Fx.nui.handle('buy', {
  input = S.struct { item = S.string, qty = S.int:between(1, 10) },
  output = S.struct { item = S.string, qty = S.int, paid = S.int, cash = S.int },
}, function(input)
  if input.item == 'gold' then return OutOfStock { item = input.item }:fail() end
  -- the server's tagged errors (InsufficientFunds, ...) reach the page as their tag
  return Fx.rpc.call('shop:buy', input, { timeout = 5000 })
end)
```

#### Fx.nui.send(msgType, payload, schema)

```lua
Fx.nui.send(msgType: string, payload?: any, schema?: Fx.Schema) -> Fx.Effect<nil, NuiInvalidMessage>
```

- **Side:** client.
- **Parameters:** `msgType`, the `type` the page listens for with `onMessage`; `payload`; `schema`, checked against `payload` first.
- **Returns:** `nil` after `SendNUIMessage({ type = msgType, payload = payload })`. With a schema, the schema's output is sent.
- **Fails with:** `NuiInvalidMessage { type, message }` when `payload` fails `schema`; nothing is sent.
- **Notes:** it is an effect, so it sends nothing until run (`Fx.yield`, `Fx.runFork`).

```lua
local Open = S.struct { title = S.string, items = S.array(S.string) }
Fx.yield(Fx.nui.send('open', { title = '24/7 Supermarket', items = { 'water', 'bread', 'phone' } }, Open))
```

#### Fx.nui.useFocus(opts)

```lua
Fx.nui.useFocus(opts?: { cursor?: boolean, keepInput?: boolean }) -> Fx.Effect<nil, never>
-- requires Scope
```

- **Side:** client.
- **Parameters:** `opts.cursor`, show the cursor (default `true`); `opts.keepInput`, also call `SetNuiFocusKeepInput(true)` so the game keeps receiving input.
- **Returns:** `nil`. Calls `SetNuiFocus(true, cursor)` when it runs.
- **Fails with:** never.
- **Notes:** when the scope closes, it calls `SetNuiFocus(false, false)` (and `SetNuiFocusKeepInput(false)` if `keepInput` was set). Focus is released however the scope ends: success, failure, interruption or resource stop.

```lua
-- /shop opens the page; the 'close' callback interrupts the fiber, which releases focus
local open

RegisterCommand('shop', function()
  if open then return end
  open = Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.nui.useFocus())
    Fx.yield(Fx.nui.send('open', { items = { 'water', 'bread', 'phone' } }))
    Fx.yield(Fx.never)
  end)):ensuring(Fx.sync(function()
    open = nil
    SendNUIMessage({ type = 'close' })
  end)))
end, false)

Fx.nui.handle('close', { input = S.struct {} }, function()
  if open then open:interruptAsFork(0) end
  return true
end)
```

### Page side: @rivolabs/fx-nui

```sh
npm install @rivolabs/fx-nui
```

The package ships ESM and CJS builds with type declarations. Its exports: `fetchNui`, `FetchNuiOptions` (type), `NuiError`, `isNuiError`, `onMessage`, `emitMessage`, `mockNui`, `isInGame`, `resourceName`, `setDevResource`. To generate the payload types from the same JSON schema as your Lua validators, see [CLI](#cli).

#### fetchNui(name, input, options)

```ts
interface FetchNuiOptions {
  /** Milliseconds before rejecting with NuiTimeout. Default 10000; 0 waits forever. */
  readonly timeout?: number
  /** Call another resource's callback (default: this page's resource). */
  readonly resource?: string
  readonly signal?: AbortSignal
}

function fetchNui<O = unknown, I = unknown>(name: string, input?: I, options?: FetchNuiOptions): Promise<O>
```

- **Side:** page.
- **Parameters:** `name`, the `Fx.nui.handle` name; `input`, the body (sent as `JSON.stringify(input ?? {})`); `options`.
- **Returns:** a promise of the handler's `value`.
- Fails with (rejects with a `NuiError`):
  - the handler's own tag, `NuiInvalidInput`, `NuiInternalError` or `NuiInterrupted`, as answered by Lua;
  - `NuiInternalError { name }` when the answer is `{ ok: false }` without a tagged `error`;
  - `NuiTimeout { name, timeoutMs }` when `timeout` runs out;
  - `NuiTransportError { name, status }` for a non-2xx HTTP response;
  - `NuiTransportError { name, message }` when `fetch` itself fails, including when `options.signal` aborts the request.
- **Notes:**
  - Posts to `https://<resource>/<name>` with `Content-Type: application/json; charset=UTF-8`, where `<resource>` is `options.resource ?? resourceName()`.
  - Answers that are not `{ ok: boolean, ... }` are returned as they are, so it also works with plain `RegisterNUICallback` handlers. An empty body resolves to `undefined`; a body that is not JSON resolves to the text.
  - Outside the game, a mock registered with `mockNui(name, ...)` answers instead and `fetch` is not called. Mocks skip the timeout, the signal and the `{ ok }` unwrapping, and an error thrown by a mock rejects unchanged (it is not wrapped in a `NuiError`).
  - A signal that is already aborted when you call `fetchNui` is not noticed; only an abort during the request cancels it.
  - The type parameters are not checked at runtime. Validate on the Lua side with `spec.output` if the page relies on the shape.

```ts
import { fetchNui, isNuiError } from "@rivolabs/fx-nui"

type Receipt = { item: string; qty: number; paid: number; cash: number }

try {
  const r = await fetchNui<Receipt>("buy", { item: "water", qty: 2 }, { timeout: 5000 })
  setStatus(`Bought ${r.qty}x ${r.item} for $${r.paid}`)
} catch (e) {
  if (isNuiError(e, "InsufficientFunds")) setStatus(`Need $${e.fields.need}, have $${e.fields.have}`)
  else if (isNuiError(e, "NuiInvalidInput")) setStatus(`Check the order: ${e.fields.message}`)
  else throw e
}
```

#### NuiError

```ts
class NuiError extends Error {
  readonly _tag: string
  readonly fields: Readonly<Record<string, unknown>>
  constructor(tag: string, fields?: Record<string, unknown>)
}
```

- **Side:** page.
- **Notes:**
  - `name` is `"NuiError"`.
  - `_tag` is the error's tag.
  - `fields` holds every field sent with the error, plus `_tag`.
  - `message` is `"<tag>: <fields.message>"` when `fields.message` is a string, otherwise just `"<tag>"`.
  - Throw one from a `mockNui` handler to simulate a Lua failure.

```ts
import { NuiError } from "@rivolabs/fx-nui"

const e = new NuiError("OutOfStock", { item: "gold" })
e._tag            // "OutOfStock"
e.fields          // { item: "gold", _tag: "OutOfStock" }
e.message         // "OutOfStock"
```

#### isNuiError(err, tag)

```ts
function isNuiError(err: unknown, tag?: string): err is NuiError
```

- **Side:** page.
- **Returns:** `true` when `err` is a `NuiError` and, if `tag` is given, its `_tag` equals `tag`. Narrows the type.
- **Fails with:** never.

```ts
catch (e) {
  if (isNuiError(e, "OutOfStock")) showSoldOut(e.fields.item as string)
}
```

#### onMessage(type, handler)

```ts
function onMessage<P = unknown>(type: string, handler: (payload: P) => void): () => void
```

- **Side:** page.
- **Parameters:** `type`, matched against `event.data.type`; `handler`, called with `event.data.payload`.
- **Returns:** a function that removes the listener.
- **Fails with:** never. Errors thrown by `handler` are not caught.
- **Notes:** listens to `window` `message` events, so it receives every `Fx.nui.send(type, payload)` from the resource and every `emitMessage(type, payload)`. Messages of other types and non-object `data` are ignored. The payload type is not checked at runtime.

```ts
import { onMessage } from "@rivolabs/fx-nui"

const stop = onMessage<{ items: string[] }>("open", ({ items }) => render(items))
// later, e.g. in a React effect cleanup
stop()
```

#### emitMessage(type, payload)

```ts
function emitMessage<P = unknown>(type: string, payload?: P): void
```

- **Side:** page.
- **Returns:** nothing. Dispatches a `MessageEvent("message", { data: { type, payload } })` on `window`, the same shape `Fx.nui.send` produces.
- **Notes:** for running the page outside the game and for tests.

```ts
import { emitMessage, isInGame } from "@rivolabs/fx-nui"

if (!isInGame()) emitMessage("open", { items: ["water", "bread", "phone"] })
```

#### mockNui(name, handler)

```ts
function mockNui<I = unknown, O = unknown>(name: string, handler: (input: I) => O | Promise<O>): () => void
```

- **Side:** page.
- **Parameters:** `name`, the callback to answer; `handler`, gets the `input` passed to `fetchNui`.
- **Returns:** a function that removes the mock (only if it is still the registered one for `name`).
- **Notes:**
  - Used only when `isInGame()` is false; in game, mocks are ignored.
  - Return a value (or a promise) to resolve the call. Throw a `NuiError` to reject it the way Lua would.
  - One mock per name; registering again replaces it.

```ts
import { mockNui, NuiError } from "@rivolabs/fx-nui"

mockNui<{ item: string; qty: number }, { item: string; qty: number; paid: number; cash: number }>("buy", ({ item, qty }) => {
  if (qty * 5 > 100) throw new NuiError("InsufficientFunds", { need: qty * 5, have: 100 })
  return { item, qty, paid: qty * 5, cash: 100 - qty * 5 }
})
```

#### isInGame()

```ts
function isInGame(): boolean
```

- **Side:** page.
- **Returns:** `true` when `globalThis.GetParentResourceName` is a function, which FiveM's CEF injects into NUI pages.

```ts
if (!isInGame()) document.body.style.background = "#333"   // no game behind the page in a browser
```

#### resourceName()

```ts
function resourceName(): string
```

- **Side:** page.
- **Returns:** `GetParentResourceName()` in game; outside the game, the name set with `setDevResource` (default `"nui-dev"`).

```ts
console.log(`page for ${resourceName()}`)
```

#### setDevResource(name)

```ts
function setDevResource(name: string): void
```

- **Side:** page.
- **Notes:** sets the name `resourceName()` returns outside the game, and so the host `fetchNui` posts to (`https://<name>/<callback>`) when no mock answers. Has no effect in game.

```ts
setDevResource("my_shop")
```

### Developing the page in a normal browser

Outside FiveM there is no `GetParentResourceName`, so `isInGame()` is false. Then:

1. Register a `mockNui` for every callback the page calls. Without a mock, `fetchNui` posts to `https://nui-dev/<name>` (or the `setDevResource` name), which normally fails with `NuiTransportError`.
2. Use `emitMessage` to play the messages the Lua side would send with `Fx.nui.send`.
3. Keep the mocks in the shipped page if you like: they are ignored in game.

```ts
// main.ts
import { emitMessage, isInGame, mockNui, NuiError } from "@rivolabs/fx-nui"

if (!isInGame()) {
  let cash = 100
  mockNui<{ item: string; qty: number }>("buy", ({ item, qty }) => {
    const paid = qty * 5
    if (paid > cash) throw new NuiError("InsufficientFunds", { need: paid, have: cash })
    cash -= paid
    return { item, qty, paid, cash }
  })
  mockNui("close", () => true)
  emitMessage("open", { items: ["water", "bread", "phone"] })
}
```

Then run any dev server (or open `index.html` directly, as the `lua-nui` template does) and work on the page with the browser's devtools. `npx rivo-fx create my_shop --template lua-nui` scaffolds a resource with a page wired this way ([CLI](#cli)).

<a id="javascript-typescript"></a>

## JavaScript and TypeScript (@rivolabs/fx)
`@rivolabs/fx` brings Rivo FX to FiveM JavaScript and TypeScript resources, built on the real
[`effect`](https://effect.website) package (version 4). It gives you validated net events with
per-player rate limits, typed RPC whose tagged errors cross the wire, a runtime that cleans up on
`onResourceStop`, player scopes, convar config, a FiveM console logger, and client asset and entity
helpers. It speaks the same wire protocol as the Lua library ([PROTOCOL.md](https://github.com/RivoLabs/rivo_fx/blob/main/docs/PROTOCOL.md)), so a
Lua client can call a TypeScript server RPC and the other way round.

### Install

```sh
pnpm add @rivolabs/fx effect     # or: npm install @rivolabs/fx effect
```

- `effect` is a peer dependency: `^4.1.0`. The package is built and tested against `effect` 4.1.0.
- FiveM loads one plain script per file, so you bundle each side, with `effect`, into a single file.
  See [Bundling a resource](#bundling-a-resource).

### Entry points

| Import | Use it in | Exports |
|---|---|---|
| `@rivolabs/fx/server` | server scripts | everything in `@rivolabs/fx`, plus `FxServer`, `Net`, `Rpc`, `RpcServer`, `PlayerScope`, `PlayerScopes`, `RateLimiter`, `SecurityEvents`, type `SecurityEvent` |
| `@rivolabs/fx/client` | client scripts | everything in `@rivolabs/fx`, plus `FxClient`, `Net`, `Rpc`, `RpcClient`, `Assets`, `Entity` |
| `@rivolabs/fx` | code shared by both sides | `FxRuntime`, `Config`, `Logger`, `Protocol`, the RPC error classes, `RemoteError`, rate-limit helpers, RPC engine types |
| `@rivolabs/fx/polyfill` | first line of every client entry | nothing; installs `TextEncoder` and `TextDecoder` |

`Net` and `Rpc` exist on both sides with different signatures. Always import them from the side
you are on.

#### Why the polyfill exists

FiveM's client JS runtime has no `TextEncoder` or `TextDecoder`. `effect` creates both when its
modules load, so a client bundle without them fails at startup with
`TextEncoder is not defined`. `@rivolabs/fx/polyfill` installs small UTF-8 versions on
`globalThis`, and does nothing where the globals already exist (server, browser, Node).

It must run before any module that imports `effect`. ES imports are evaluated in order, and the
built `@rivolabs/fx/client` file itself starts with `import ... from "effect"`, so it cannot fix
this on its own. Import the polyfill first, by itself:

```ts
import "@rivolabs/fx/polyfill"          // first, before anything that imports effect
import { Effect, Layer } from "effect"
import { FxClient, FxRuntime } from "@rivolabs/fx/client"
```

Server entries do not need it.

### A complete resource

```ts
// src/server.ts
import { Effect, Layer, Schema, Stream } from "effect"
import { Config, FxRuntime, FxServer, Net, Rpc, SecurityEvents } from "@rivolabs/fx/server"

class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

const Main = Layer.effectDiscard(Effect.gen(function* () {
  const maxDeposit = yield* Config.integer("bank:maxDeposit")    // set bank:maxDeposit 5000

  yield* Net.handle("bank:deposit", Schema.Struct({ amount: Schema.Int }), (source, { amount }) =>
    Effect.gen(function* () {
      yield* Effect.log(`player ${source} deposited ${Math.min(amount, maxDeposit)}`)
      yield* Net.emitClient("bank:updated", source, amount)
    }), { rateLimit: "5/s" })

  yield* Rpc.register("bank:withdraw",
    { input: Schema.Struct({ amount: Schema.Int }), output: Schema.Number },
    (source, { amount }) => amount > 100
      ? Effect.fail(new NotEnoughMoney({ balance: 100, wanted: amount }))
      : Effect.succeed(100 - amount))

  yield* SecurityEvents.stream.pipe(
    Stream.runForEach((e) => Effect.logWarning(`${e.kind} from ${e.source} on ${e.name}`)),
    Effect.forkScoped
  )
}))

export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
```

```ts
// src/client.ts
import "@rivolabs/fx/polyfill"
import { Effect, Layer, Schema } from "effect"
import { FxClient, FxRuntime, Net, Rpc } from "@rivolabs/fx/client"

const Main = Layer.effectDiscard(Effect.gen(function* () {
  yield* Net.handle("bank:updated", Schema.Number, (amount) => Effect.log(`deposited ${amount}`))
}))

const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxClient.layer)))

RegisterCommand("withdraw", () => {
  runtime.runFork(
    Rpc.call("bank:withdraw", { amount: 500 }, { output: Schema.Number, timeout: 5_000 }).pipe(
      Effect.flatMap((left) => Effect.log(`balance ${left}`)),
      Effect.catchTag("NotEnoughMoney", (e) => Effect.log(`only ${String(e["balance"])} left`)),
      Effect.catchTag("RpcTimeout", () => Effect.log("the bank did not answer"))
    )
  )
}, false)
```

Everything registered inside `Main` lives in the runtime's scope. When the resource stops, the
runtime is disposed: listeners are removed, fibers are interrupted and finalizers run, inside the
`onResourceStop` handler.

### Runtime

#### FxRuntime.make(layer, options?)

```ts
export const make: <R, E>(layer: Layer.Layer<R, E, never>, options?: FxRuntimeOptions) => FxRuntime<R, E>

export interface FxRuntime<R, E> extends ManagedRuntime.ManagedRuntime<R, E> {
  readonly stop: () => void
}
export interface FxRuntimeOptions {
  readonly resource?: string
}
```

- Parameters:
  - `layer`: a fully provided layer (no requirements left). Usually `Main.pipe(Layer.provideMerge(FxServer.layer))`.
  - `options.resource`: the resource whose `onResourceStop` disposes the runtime. Defaults to `GetCurrentResourceName()`.
- Returns: a `ManagedRuntime` with an extra `stop()` that disposes it now and flushes pending work synchronously.
- Fails with: nothing synchronously. If the layer fails to build, the cause is printed with `console.error` as `[rivo_fx] failed to start the runtime:` followed by the pretty cause.
- Notes:
  - The layer starts building immediately and as far as it can without waiting, so net handlers and RPCs are registered before your script finishes loading.
  - It uses a `FlushableScheduler`, so disposal can run every finalizer inside `onResourceStop`, before FiveM tears the JS context down.
  - Use `Layer.provideMerge(FxServer.layer)` rather than `Layer.provide` when you want to call `runtime.runFork(...)` with effects that need `Rpc`, `Net` and so on. `provide` hides those services from the runtime's output.
  - `stop()` is idempotent and removes the `onResourceStop` listener.
- Example:

```ts
const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
runtime.runFork(Net.broadcast("shop:reopened"))
```

#### FxRuntime.FlushableScheduler

```ts
export class FlushableScheduler implements Scheduler.Scheduler {
  readonly executionMode: "async"
  shouldYield(fiber: Parameters<Scheduler.Scheduler["shouldYield"]>[0]): boolean
  makeDispatcher(): Scheduler.SchedulerDispatcher
  flush(): void
}
```

- Notes: the scheduler `FxRuntime.make` installs. All fibers share one dispatcher, and `flush()` runs every queued task, including tasks queued while flushing. You only need it if you build your own `ManagedRuntime`.

#### FxServer.layer

```ts
export type Services = SecurityEvents | RateLimiter | RpcServer | PlayerScopes
export const layer: Layer.Layer<Services>
```

- Returns: one layer with `SecurityEvents`, `RateLimiter`, `RpcServer` (RPC host and caller), `PlayerScopes`, the convar `ConfigProvider` from `Config.layer()` and the FiveM logger from `Logger.layer`.
- Notes: provide it to your main layer with `Layer.provideMerge`. It needs `@rivolabs/fx/server` (server typings).
- Example:

```ts
export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
```

#### FxClient.layer

```ts
export type Services = RpcClient
export const layer: Layer.Layer<Services>
```

- Returns: `RpcClient` (RPC caller and host), the convar `ConfigProvider` and the FiveM logger.
- Example:

```ts
const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxClient.layer)))
```

### Server: net events

#### Net.handle(name, schema, handler, options?) (server)

```ts
export const handle: <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (source: number, input: S["Type"]) => Effect.Effect<unknown, unknown, R>,
  options?: HandleOptions
) => Effect.Effect<void, never, SecurityEvents | RateLimiter | Scope.Scope | R>

export interface HandleOptions {
  readonly rateLimit?: RateLimit | false | undefined
}
```

- Parameters:
  - `name`: the FiveM net event name.
  - `schema`: an Effect schema for the single payload argument.
  - `handler`: runs with the player id and the decoded payload.
  - `options.rateLimit`: `"<n>/s"`, `"<n>/m"` or `"<n>/h"`. Defaults to `"10/s"` per player. `false` disables it.
- Returns: an effect that registers the listener for the lifetime of the current `Scope`.
- Fails with: never. Rejections are published as `SecurityEvent`s:
  - over the limit: `rate_limited` (logged at Debug level), handler not run;
  - payload fails the schema: `invalid_payload` with the schema message (logged as a warning), handler not run.
- Notes:
  - The event carries exactly one argument, the payload. Clients send `TriggerServerEvent(name, payload)`. Extra positional arguments are ignored, so send an object.
  - Events with no player source (a server-side `TriggerEvent`) are ignored.
  - The rate limit is checked before the schema. Each (player, event) pair has its own token bucket, and buckets are forgotten when the player drops.
  - Each call runs on its own fiber. A handler failure or defect is logged with `Effect.logError` as `net event "<name>" failed`. The handler is interrupted if the player drops, and when the registering scope closes.
- Example:

```ts
yield* Net.handle("shop:buy", Schema.Struct({ item: Schema.String, qty: Schema.Int }), (source, { item, qty }) =>
  Effect.log(`${source} bought ${qty}x ${item}`), { rateLimit: "5/s" })
```

#### Net.emitClient(name, player, payload?)

```ts
export const emitClient: (name: string, player: number, payload?: unknown) => Effect.Effect<void>
```

- Parameters: event name, target player id (`-1` for everyone), one payload.
- Returns: an effect that calls `TriggerClientEvent(name, player, payload)`.
- Example:

```ts
yield* Net.emitClient("bank:updated", source, { balance: 250 })
```

#### Net.broadcast(name, payload?)

```ts
export const broadcast: (name: string, payload?: unknown) => Effect.Effect<void>
```

- Returns: an effect that calls `TriggerClientEvent(name, -1, payload)`.
- Example:

```ts
yield* Net.broadcast("weather:changed", { type: "RAIN" })
```

### Server: RPC

#### Rpc.register(name, options, handler) (server)

```ts
export const register: <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (source: number, input: I["Type"]) => Effect.Effect<A, E, R>
) => Effect.Effect<void, never, RpcServer | RateLimiter | Scope.Scope | R>

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  readonly input: I
  readonly output?: Schema.Codec<A, unknown> | undefined
  readonly rateLimit?: RateLimit | false | undefined
}
```

- Parameters:
  - `name`: the RPC name callers use.
  - `options.input`: required schema for the request input. Use `Schema.Unknown` to accept anything on purpose.
  - `options.output`: optional codec. The handler's value is encoded with it before it is sent.
  - `options.rateLimit`: per-player token bucket, default `"10/s"`, `false` to disable. RPC buckets are separate from net event buckets with the same name.
  - `handler`: gets the player id and the decoded input.
- Returns: an effect that registers the handler for the lifetime of the current `Scope`. Registering the same name again replaces the earlier handler.
- Fails with (sent to the caller, see [Errors](#error-classes)):
  - `RpcNotFound` when no handler has that name (publishes `unknown_rpc`, not rate limited);
  - `RpcRateLimited` over the limit (publishes `rate_limited`);
  - `RpcInvalidInput` when the input fails `options.input` (publishes `invalid_payload`);
  - the handler's own tagged error, with its `_tag` and fields;
  - `RpcInternalError` for a defect, a failure without a `_tag`, a tagged failure that comes with a defect, or an output that fails to encode.
- Notes:
  - Requests are processed in this order: envelope, name, rate limit, input. A malformed envelope gets no reply and publishes `invalid_payload` named `__rfx:<resource>:req`.
  - The handler runs in a span `rpc.server <name>` that continues the caller's trace (see [Tracing](#tracing)).
  - If the caller cancels (its timeout fired or its fiber was interrupted) or the player drops, the handler fiber is interrupted and no response is sent.
  - Defects are logged on the server with `Effect.logError` as `RPC "<name>" died`. Their details never reach the client.
- Example:

```ts
class OutOfStock extends Schema.TaggedError<OutOfStock>()("OutOfStock", { item: Schema.String }) {}

yield* Rpc.register("shop:buy",
  { input: Schema.Struct({ item: Schema.String }), output: Schema.Struct({ item: Schema.String }) },
  (source, { item }) => item === "phone"
    ? Effect.fail(new OutOfStock({ item }))
    : Effect.succeed({ item }))
```

#### Rpc.callClient(player, name, input, options?)

```ts
export const callClient: <A = unknown, E = never>(
  player: number,
  name: string,
  input: unknown,
  options?: CallClientOptions<A, E>
) => Effect.Effect<A, E | RpcError | RemoteError, RpcServer>

export interface CallClientOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  readonly output?: Schema.Decoder<A> | undefined
  readonly errors?: Schema.Decoder<E> | undefined
}
// inherited from CallOptions:
//   readonly resource?: string | undefined   resource hosting the RPC, default: this resource
//   readonly timeout?: number | undefined    milliseconds, default 10 000
```

- Parameters: the player id, the RPC name registered on that player's client, the input, and options.
- Returns: the client's value, decoded with `output` when given.
- Fails with: `RpcTimeout`, `RpcNotFound`, `RpcInvalidInput`, `RpcInternalError`, `RpcInvalidOutput`, your class when `errors` decodes the tag, or `RemoteError` for any other tag. Client hosts have no rate limit, so `RpcRateLimited` only comes from a server host.
- Notes: a response is matched on (player, id), so only the player you called can answer. Interrupting the call, including by its timeout, sends the cancel event and the client interrupts its handler.
- Example:

```ts
const ok = yield* Rpc.callClient(source, "ui:confirm", { text: "Buy?" }, { output: Schema.Boolean, timeout: 5_000 })
```

#### RpcServer

```ts
export class RpcServer extends Context.Service<RpcServer, {
  readonly host: Host<number>
  readonly caller: Caller<number>
}>()("@rivolabs/fx/RpcServer") {
  static readonly layer: Layer.Layer<RpcServer, never, SecurityEvents>
}
```

- Notes: the service behind `Rpc.register` and `Rpc.callClient`. Part of `FxServer.layer`. It listens on `__rfx:<resource>:req`, `:cancel` and `:res`. `Rpc.serverTransport` (a `Transport<number>`) is exported for building your own host or caller.

### Server: player scopes

One `Scope` per connected player, created on first use and closed on `playerDropped` (and when the
runtime is disposed). Put per-player work and cleanup in it.

#### PlayerScope.get(player)

```ts
export const get: (player: number) => Effect.Effect<Scope.Scope, never, PlayerScopes>
```

- Returns: the player's scope, created on first use.
- Example:

```ts
const scope = yield* PlayerScope.get(source)
```

#### PlayerScope.fork(player, effect)

```ts
export const fork: <A, E, R>(player: number, effect: Effect.Effect<A, E, R>) =>
  Effect.Effect<Fiber.Fiber<A, E>, never, PlayerScopes | R>
```

- Returns: the fiber, forked into the player's scope. It is interrupted when the player drops.
- Example:

```ts
yield* PlayerScope.fork(source, Effect.forever(Effect.sleep("1 minute").pipe(Effect.andThen(Effect.log(`pay ${source}`)))))
```

#### PlayerScope.addFinalizer(player, finalizer)

```ts
export const addFinalizer: <R>(player: number, finalizer: Effect.Effect<void, never, R>) =>
  Effect.Effect<void, never, PlayerScopes | R>
```

- Notes: `finalizer` runs when the player drops or the runtime is disposed. Services it needs are captured when you call `addFinalizer`.
- Example:

```ts
yield* PlayerScope.addFinalizer(source, Effect.log(`saving ${source}`))
```

#### PlayerScope.scoped(player, effect)

```ts
export const scoped: <A, E, R>(player: number, effect: Effect.Effect<A, E, R>) =>
  Effect.Effect<A, E, PlayerScopes | Exclude<R, Scope.Scope>>
```

- Returns: the result of `effect`, run with the player's scope as its `Scope`. Anything it acquires with `Effect.acquireRelease` is released when the player drops.
- Example:

```ts
const vehicle = yield* PlayerScope.scoped(source, Effect.acquireRelease(
  Effect.sync(() => CreateVehicle(GetHashKey("adder"), 0, 0, 72, 0, true, true)),
  (veh) => Effect.sync(() => DeleteEntity(veh))
))
```

#### PlayerScopes

```ts
export class PlayerScopes extends Context.Service<PlayerScopes, {
  readonly scope: (player: number) => Effect.Effect<Scope.Scope>
}>()("@rivolabs/fx/PlayerScopes") {
  static readonly layer: Layer.Layer<PlayerScopes>
}
```

- Notes: the service behind `PlayerScope.*`. Part of `FxServer.layer`. Also exported as `PlayerScope.PlayerScopes`.

### Server: rate limiting and security events

#### RateLimiter

```ts
export class RateLimiter extends Context.Service<RateLimiter, {
  readonly buckets: (kind: "net" | "rpc", name: string, limit: RateLimit) => TokenBuckets
}>()("@rivolabs/fx/RateLimiter") {
  static readonly layer: Layer.Layer<RateLimiter>
}
```

- Notes: owns the token buckets used by `Net.handle` and `Rpc.register`. One bucket set per (kind, name, limit). Keys inside a set are `"<player>|<name>"`. A player's buckets are deleted on `playerDropped`. Part of `FxServer.layer`.
- Fails with: `buckets` throws `Invalid rate limit "<limit>": expected "<n>/s", "<n>/m" or "<n>/h" with n > 0` for a malformed limit. Inside `Net.handle` or `Rpc.register` that becomes a defect and the layer fails to build.

#### SecurityEvent

```ts
export interface SecurityEvent {
  readonly kind: "invalid_payload" | "rate_limited" | "unknown_rpc"
  readonly source: number
  readonly name: string
  readonly message?: string | undefined
}
```

- Notes: something a client sent that the server rejected. `source` is the player id, `name` the event or RPC name. The Lua library adds a fourth kind, `invalid_state`, and a `resource` field; the JS package has neither.

#### SecurityEvents.publish(event)

```ts
export const publish: (event: SecurityEvent) => Effect.Effect<void, never, SecurityEvents>
```

- Notes: logs the event (`rate_limited` at Debug, the others as warnings), publishes it inside the resource, and fires `emit("rivo_fx:security", event, resourceName)` so one anticheat resource can watch every resource. Use it to report your own rejections.
- Example:

```ts
yield* SecurityEvents.publish({ kind: "invalid_payload", source, name: "shop:buy", message: "price mismatch" })
```

#### SecurityEvents.subscribe

```ts
export const subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, SecurityEvents | Scope.Scope>
```

- Returns: a subscription for the lifetime of the current scope. Events published before subscribing are not seen.

#### SecurityEvents.stream

```ts
export const stream: Stream.Stream<SecurityEvent, never, SecurityEvents>
```

- Returns: every security event from when the stream starts.
- Example:

```ts
yield* SecurityEvents.stream.pipe(
  Stream.filter((e) => e.kind !== "rate_limited"),
  Stream.runForEach((e) => Effect.logWarning(`${e.kind} from ${e.source} on ${e.name}`)),
  Effect.forkScoped
)
```

#### SecurityEvents.SecurityEvents

```ts
export class SecurityEvents extends Context.Service<SecurityEvents, {
  readonly publish: (event: SecurityEvent) => Effect.Effect<void>
  readonly subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, Scope.Scope>
  readonly stream: Stream.Stream<SecurityEvent>
}>()("@rivolabs/fx/SecurityEvents") {
  static readonly layer: Layer.Layer<SecurityEvents>
}
```

- Notes: the service class. From `@rivolabs/fx/server`, `SecurityEvents` is the module namespace, so the class is `SecurityEvents.SecurityEvents`. Part of `FxServer.layer`.

### Client: net events

#### Net.handle(name, schema, handler) (client)

```ts
export const handle: <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (input: S["Type"]) => Effect.Effect<unknown, unknown, R>
) => Effect.Effect<void, never, Scope.Scope | R>
```

- Parameters: event name, payload schema, handler (no source: it is always the server).
- Returns: an effect that registers the listener for the lifetime of the current scope.
- Fails with: never. An invalid payload is logged as a warning (`net event "<name>": invalid payload`) and the handler does not run. A handler failure is logged as `net event "<name>" failed`.
- Notes: no rate limit on the client.
- Example:

```ts
yield* Net.handle("bank:updated", Schema.Struct({ balance: Schema.Number }), ({ balance }) =>
  Effect.log(`balance ${balance}`))
```

#### Net.emitServer(name, payload?)

```ts
export const emitServer: (name: string, payload?: unknown) => Effect.Effect<void>
```

- Returns: an effect that calls `TriggerServerEvent(name, payload)`.
- Example:

```ts
yield* Net.emitServer("shop:buy", { item: "water", qty: 2 })
```

### Client: RPC

#### Rpc.call(name, input, options?)

```ts
export const call: <A = unknown, E = never>(
  name: string,
  input: unknown,
  options?: ClientCallOptions<A, E>
) => Effect.Effect<A, E | RpcError | RemoteError, RpcClient>

export interface ClientCallOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  readonly output?: Schema.Decoder<A> | undefined
  readonly errors?: Schema.Decoder<E> | undefined
}
// inherited from CallOptions:
//   readonly resource?: string | undefined   resource hosting the RPC, default: this resource
//   readonly timeout?: number | undefined    milliseconds, default 10 000
```

- Parameters:
  - `name`, `input`: the RPC and its input. Send one value (usually an object).
  - `options.output`: validates the response. A mismatch fails with `RpcInvalidOutput`.
  - `options.errors`: decodes known error tags into your own classes, for example `NotEnoughMoney` or a `Schema.Union([A, B])` of `Schema.TaggedError` classes.
  - `options.resource`: the resource hosting the RPC. Set it when calling another resource.
  - `options.timeout`: milliseconds before `RpcTimeout`, default 10 000.
- Returns: the server's value.
- Fails with:
  - `RpcTimeout` (local), `RpcInvalidOutput` (local), `RpcNotFound`, `RpcInvalidInput`, `RpcRateLimited`, `RpcInternalError`, rebuilt as their real classes;
  - your class, when `errors` decodes the tag;
  - otherwise `RemoteError` with the same `_tag` and fields, so `Effect.catchTag("NotEnoughMoney", ...)` works.
- Notes:
  - The call runs in a span `rpc.client <name>` and sends its traceparent. Interrupting the call, including by its timeout, sends `__rfx:<target>:cancel` and the server interrupts its handler.
  - The error type always includes `RemoteError`, whose `_tag` is typed `string`. So even with `errors: NotEnoughMoney`, `Effect.catchTag("NotEnoughMoney", (e) => ...)` types `e` as `NotEnoughMoney | RemoteError`. At runtime it is your class; narrow with `instanceof` to read typed fields.
- Example:

```ts
class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

const left = yield* Rpc.call("bank:withdraw", { amount: 50 }, { output: Schema.Number, errors: NotEnoughMoney }).pipe(
  Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(e instanceof NotEnoughMoney ? e.balance : 0))
)
```

#### Rpc.register(name, options, handler) (client)

```ts
export const register: <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (input: I["Type"]) => Effect.Effect<A, E, R>
) => Effect.Effect<void, never, RpcClient | Scope.Scope | R>

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  readonly input: I
  readonly output?: Schema.Codec<A, unknown> | undefined
}
```

- Parameters: RPC name, input schema (required), optional output codec, handler (no source).
- Returns: an effect that registers a server → client RPC for the lifetime of the current scope.
- Fails with (sent to the server): `RpcNotFound`, `RpcInvalidInput`, the handler's tagged error, or `RpcInternalError`.
- Notes: no rate limit and no security events on the client.
- Example:

```ts
yield* Rpc.register("ui:confirm", { input: Schema.Struct({ text: Schema.String }), output: Schema.Boolean },
  ({ text }) => Effect.succeed(text.length > 0))
```

#### RpcClient

```ts
export type Server = "server"
export class RpcClient extends Context.Service<RpcClient, {
  readonly host: Host<Server>
  readonly caller: Caller<Server>
}>()("@rivolabs/fx/RpcClient") {
  static readonly layer: Layer.Layer<RpcClient>
}
```

- Notes: the service behind client `Rpc.call` and `Rpc.register`. Part of `FxClient.layer`. `Rpc.clientTransport` (a `Transport<"server">`) is exported too.

### Client: assets

```ts
export interface LoadOptions {
  readonly timeout?: number | undefined    // ms before AssetTimeout, default 10 000
  readonly interval?: number | undefined   // ms between HasXLoaded checks, default 0 (every tick)
}
```

#### Assets.model(model, options?)

```ts
export const model: (model: string | number, options?: LoadOptions) => Effect.Effect<number, InvalidModel | AssetTimeout>
```

- Parameters: a model name (hashed with `GetHashKey`) or hash, and load options.
- Returns: the model hash once `HasModelLoaded` is true.
- Fails with: `InvalidModel { model }` when `IsModelInCdimage` or `IsModelValid` is false; `AssetTimeout { kind: "model", asset, timeoutMs }`.
- Notes: a request that times out is released with `SetModelAsNoLongerNeeded`. The model stays loaded on success; use `modelScoped` to release it.
- Example:

```ts
const hash = yield* Assets.model("adder", { timeout: 5_000 })
```

#### Assets.modelScoped(name, options?)

```ts
export const modelScoped: (name: string | number, options?: LoadOptions) =>
  Effect.Effect<number, InvalidModel | AssetTimeout, Scope.Scope>
```

- Notes: `Assets.model`, released with `SetModelAsNoLongerNeeded` when the scope closes.
- Example:

```ts
const veh = yield* Effect.scoped(Effect.gen(function* () {
  const hash = yield* Assets.modelScoped("adder", { timeout: 5_000 })
  const [x, y, z] = GetEntityCoords(PlayerPedId(), true) as [number, number, number]
  return CreateVehicle(hash, x, y, z, 0, true, false)
}))
```

#### Assets.animDict(dict, options?)

```ts
export const animDict: (dict: string, options?: LoadOptions) => Effect.Effect<string, InvalidAnimDict | AssetTimeout>
```

- Fails with: `InvalidAnimDict { animDict }` when `DoesAnimDictExist` is false; `AssetTimeout { kind: "animDict", ... }`.
- Example:

```ts
const dict = yield* Assets.animDict("missfbi1", { timeout: 3_000 })
```

#### Assets.animDictScoped(dict, options?)

```ts
export const animDictScoped: (dict: string, options?: LoadOptions) =>
  Effect.Effect<string, InvalidAnimDict | AssetTimeout, Scope.Scope>
```

- Notes: released with `RemoveAnimDict` when the scope closes.

#### Assets.ptfxAsset(asset, options?)

```ts
export const ptfxAsset: (asset: string, options?: LoadOptions) => Effect.Effect<string, AssetTimeout>
```

- Fails with: `AssetTimeout { kind: "ptfxAsset", ... }`. There is no existence check.
- Example:

```ts
yield* Assets.ptfxAsset("core")
```

#### Assets.ptfxAssetScoped(asset, options?)

```ts
export const ptfxAssetScoped: (asset: string, options?: LoadOptions) => Effect.Effect<string, AssetTimeout, Scope.Scope>
```

- Notes: released with `RemoveNamedPtfxAsset` when the scope closes.

### Client: entities

```ts
export interface WaitOptions {
  readonly timeout?: number | undefined    // ms before EntityTimeout, default 5 000
  readonly interval?: number | undefined   // ms between checks, default 0 (every tick)
}
```

#### Entity.requestControl(entity, options?)

```ts
export const requestControl: (entity: number, options?: WaitOptions) => Effect.Effect<number, EntityNotFound | EntityTimeout>
```

- Returns: the entity, once `NetworkHasControlOfEntity` is true. It calls `NetworkRequestControlOfEntity` on every check.
- Fails with: `EntityNotFound { entity }` when the handle does not exist; `EntityTimeout { operation: "requestControl", id, timeoutMs }`.
- Example:

```ts
const veh = yield* Entity.requestControl(GetVehiclePedIsIn(PlayerPedId(), false), { timeout: 2_000 })
```

#### Entity.fromNetId(netId, options?)

```ts
export const fromNetId: (netId: number, options?: WaitOptions) => Effect.Effect<number, EntityTimeout>
```

- Returns: the local entity handle once the network id exists on this client.
- Fails with: `EntityTimeout { operation: "fromNetId", id, timeoutMs }`.
- Example:

```ts
const veh = yield* Entity.fromNetId(netId, { timeout: 5_000 })
```

### Shared: config

#### Config.layer(options?)

```ts
export const layer: (options?: ConvarProviderOptions) => Layer.Layer<never>
export interface ConvarProviderOptions {
  readonly separator?: string   // joins nested config paths, default ":"
}
```

- Returns: a layer that replaces the active `ConfigProvider` with `Config.convarProvider(options)`. Already part of `FxServer.layer` and `FxClient.layer`.
- Notes: any Effect `Config` then reads convars. Nested paths join with the separator: `Config.Boolean("debug").pipe(Config.nested("my_res"))` reads `my_res:debug`.
- Example:

```ts
import { Config as EffectConfig } from "effect"

const debug = yield* EffectConfig.Boolean("debug").pipe(EffectConfig.nested("my_res"))   // set my_res:debug true
```

#### Config.convarProvider(options?)

```ts
export const convarProvider: (options?: ConvarProviderOptions) => ConfigProvider.ConfigProvider
```

- Notes: an Effect `ConfigProvider` backed by `GetConvar`. An unset convar is "missing", so `Config.withDefault` and `Config.option` work. A convar set to an empty string is the value `""`, not missing (the Lua `Fx.config` treats `""` as unset).

#### Config.integer(name)

```ts
export const integer: (name: string) => Config.Config<number>
```

- Returns: Effect's `Config.Int(name)`. Read it with `yield*`.
- Fails with: Effect's `ConfigError` (`_tag: "ConfigError"`) when the convar is unset or does not parse.
- Example:

```ts
const max = yield* Config.integer("my_max")   // set my_max 32
```

#### Config.number(name)

```ts
export const number: (name: string) => Config.Config<number>
```

- Returns: Effect's `Config.Number(name)`.

#### Config.string(name)

```ts
export const string: (name: string) => Config.Config<string>
```

- Returns: Effect's `Config.String(name)`.

#### Config.boolean(name)

```ts
export const boolean: (name: string) => Config.Config<boolean>
```

- Returns: Effect's `Config.Boolean(name)`.

### Shared: logger

#### Logger.layer

```ts
export const layer: Layer.Layer<never>
```

- Notes: replaces the default Effect logger with `Logger.fivemLogger` and sets `References.MinimumLogLevel` from the `rivo_fx:logLevel` convar, read once when the layer builds (`Info` when unset or invalid). Part of `FxServer.layer` and `FxClient.layer`.
- Example (server.cfg):

```cfg
set rivo_fx:logLevel Debug
```

#### Logger.fivemLogger

```ts
export const fivemLogger: Logger.Logger<unknown, void>
```

- Notes: prints each line through `console.log` with FiveM color codes, for every level. FiveM's own `console.warn` and `console.error` would add a second prefix, so they are not used.

#### Logger.formatLine(options)

```ts
export const formatLine: (options: Logger.Options<unknown>) => string
```

- Returns: `^5[INFO]^7 message`, with the pretty cause on the following lines when the log has one.

#### Logger.parseLogLevel(value)

```ts
export const parseLogLevel: (value: string) => LogLevel.LogLevel | undefined
```

- Returns: the Effect level for a name, case-insensitive and trimmed (`"debug"` gives `"Debug"`), or `undefined`.

#### Logger.convarLogLevel()

```ts
export const convarLogLevel: () => LogLevel.LogLevel
```

- Returns: the level named by `rivo_fx:logLevel`, or `"Info"`.

#### Logger.colors

```ts
export const colors: Record<LogLevel.LogLevel, string>
// { All: "^7", Fatal: "^8", Error: "^1", Warn: "^3", Info: "^5", Debug: "^6", Trace: "^9", None: "^7" }
```

#### Logger.LOG_LEVEL_CONVAR

```ts
export const LOG_LEVEL_CONVAR = "rivo_fx:logLevel"
```

### Shared: rate limits

#### parseRateLimit(limit)

```ts
export type RateLimit = `${number}/${"s" | "m" | "h"}`
export interface ParsedRateLimit { readonly capacity: number; readonly periodMs: number }
export const parseRateLimit: (limit: RateLimit | string) => ParsedRateLimit
```

- Returns: `{ capacity: 10, periodMs: 1000 }` for `"10/s"`.
- Fails with: throws `Invalid rate limit "<limit>": expected "<n>/s", "<n>/m" or "<n>/h" with n > 0`. No spaces are allowed (the Lua parser accepts them).
- Example:

```ts
const { capacity, periodMs } = parseRateLimit("30/m")   // 30, 60000
```

#### TokenBuckets

```ts
export class TokenBuckets {
  constructor(limit: ParsedRateLimit)
  take(key: string, now: number): boolean
  deletePrefix(prefix: string): void
  get size(): number
}
```

- Notes: a set of token buckets sharing one limit. Capacity `n`, refilled continuously at `n` per period. `take` returns `false` when the key's bucket is empty. Time is passed in, so it works with Effect's `Clock` and `TestClock`.
- Example:

```ts
const buckets = new TokenBuckets(parseRateLimit("1/m"))
const now = yield* Clock.currentTimeMillis
if (!buckets.take(`${source}|daily`, now)) yield* Effect.log("too soon")
```

#### DEFAULT_RATE_LIMIT

```ts
export const DEFAULT_RATE_LIMIT: RateLimit   // "10/s"
```

### Shared: protocol helpers

`Protocol` holds the wire shapes and event names from [PROTOCOL.md](https://github.com/RivoLabs/rivo_fx/blob/main/docs/PROTOCOL.md). You need them
only to talk to Rivo FX resources without the `Rpc` modules, or to test them.

#### Protocol.reqEvent(resource)

```ts
export const reqEvent: (resource: string) => string      // "__rfx:<resource>:req"
export const resEvent: (resource: string) => string      // "__rfx:<resource>:res"
export const cancelEvent: (resource: string) => string   // "__rfx:<resource>:cancel"
export const SECURITY_EVENT = "rivo_fx:security"
```

- Notes: `resEvent` and `cancelEvent` follow the same pattern. `SECURITY_EVENT` is the local event every security event is mirrored to.

#### Protocol.parseRequest(u)

```ts
export interface RpcRequest {
  readonly id: number
  readonly name: string
  readonly from: string
  readonly input: unknown
  readonly trace?: string
}
export const parseRequest: (u: unknown) => RpcRequest | undefined
```

- Returns: the request, or `undefined` when `id` is not an integer or `name`/`from` are not non-empty strings. A `trace` that is not a string of at most 64 characters is dropped, not rejected.

#### Protocol.parseResponse(u)

```ts
export type RpcResponse =
  | { readonly id: number; readonly ok: true; readonly value: unknown }
  | { readonly id: number; readonly ok: false; readonly error: WireError }
export const parseResponse: (u: unknown) => RpcResponse | undefined
```

#### Protocol.parseCancel(u)

```ts
export interface RpcCancel { readonly id: number; readonly from: string }
export const parseCancel: (u: unknown) => RpcCancel | undefined
```

#### Protocol.parseTraceparent(s)

```ts
export const parseTraceparent: (s: string | undefined) => { traceId: string; spanId: string } | undefined
```

- Returns: the ids from a W3C traceparent (`00-<32 hex>-<16 hex>-<2 hex>`), or `undefined` for version `ff`, all-zero ids, or anything malformed.

#### Protocol.formatTraceparent(traceId, spanId)

```ts
export const formatTraceparent: (traceId: string, spanId: string) => string | undefined
```

- Returns: `00-<traceId>-<spanId>-01`, or `undefined` when the ids are not W3C shaped.
- Example:

```ts
Protocol.formatTraceparent("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331")
// "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
```

### Shared: RPC engine types

These types describe the engine both `Rpc` modules are built on. They are exported for advanced use
and tests; there is no public constructor for a host or caller besides the `RpcServer` and
`RpcClient` layers.

```ts
export interface Transport<P> {
  readonly listen: (event: string, callback: (peer: P, payload: unknown) => void) => () => void
  readonly send: (peer: P, event: string, payload: unknown) => void
  readonly peerKey: (peer: P) => string
}
export type RejectionKind = "invalid_payload" | "rate_limited" | "unknown_rpc"
export interface HostOptions<P> {
  readonly resource: string
  readonly onReject?: (peer: P, kind: RejectionKind, name: string, message?: string) => Effect.Effect<void>
}
export interface HostEntry<P> {
  readonly input: Schema.Decoder<unknown>
  readonly output?: Schema.Codec<unknown, unknown> | undefined
  readonly limiter?: TokenBuckets | undefined
  readonly handler: (peer: P, input: unknown) => Effect.Effect<unknown, unknown>
}
export interface Host<P> {
  readonly register: (name: string, entry: HostEntry<P>) => Effect.Effect<void, never, Scope.Scope>
}
export interface CallOptions {
  readonly resource?: string | undefined
  readonly timeout?: number | undefined
  readonly output?: Schema.Decoder<unknown> | undefined
  readonly errors?: Schema.Decoder<unknown> | undefined
}
export interface Caller<P> {
  readonly call: (peer: P, name: string, input: unknown, options?: CallOptions) => Effect.Effect<unknown, unknown>
}
```

### Error classes

Every class below is a `Schema.TaggedError`, so `Effect.catchTag` works on its `_tag`. All are
exported from `@rivolabs/fx` (and re-exported from `/server` and `/client`), except the asset and
entity errors, which live on the client modules.

| Class | Import | Fields | When |
|---|---|---|---|
| `RpcNotFound` | `@rivolabs/fx` | `name` | no handler with that name on the host |
| `RpcInvalidInput` | `@rivolabs/fx` | `name`, `message` | the input failed the host's schema |
| `RpcRateLimited` | `@rivolabs/fx` | `name` | the caller exceeded the handler's rate limit |
| `RpcInternalError` | `@rivolabs/fx` | `name` | the handler died, failed without a `_tag`, or its output failed to encode |
| `RpcTimeout` | `@rivolabs/fx` | `name`, `timeoutMs` | raised on the caller when no response arrived in time |
| `RpcInvalidOutput` | `@rivolabs/fx` | `name`, `message` | raised on the caller when the response failed `output` |
| `RemoteError` | `@rivolabs/fx` | `_tag` plus any fields | any other tag the host failed with, when `errors` did not decode it |
| `Assets.InvalidModel` | `@rivolabs/fx/client` | `model` (string or number) | model not in the CD image or not valid |
| `Assets.InvalidAnimDict` | `@rivolabs/fx/client` | `animDict` | `DoesAnimDictExist` is false |
| `Assets.AssetTimeout` | `@rivolabs/fx/client` | `kind` (`"model"`, `"animDict"`, `"ptfxAsset"`), `asset`, `timeoutMs` | the asset did not load in time |
| `Entity.EntityNotFound` | `@rivolabs/fx/client` | `entity` | the handle does not exist |
| `Entity.EntityTimeout` | `@rivolabs/fx/client` | `operation` (`"requestControl"`, `"fromNetId"`), `id`, `timeoutMs` | control or the network id did not resolve in time |

```ts
export type RpcError = RpcNotFound | RpcInvalidInput | RpcRateLimited | RpcInternalError | RpcTimeout | RpcInvalidOutput
export class RemoteError extends Data.Error<{ readonly _tag: string; readonly [field: string]: unknown }> {}
export interface WireError { readonly _tag: string; readonly [field: string]: unknown }
```

How errors cross the wire:

- Only expected failures with a string `_tag` cross. The host sends the error's own enumerable fields plus `_tag`, and `message` when it is a non-empty string. Functions, symbols and `stack` are dropped.
- A defect anywhere in the cause wins: the caller gets `RpcInternalError { name }` and the details stay in the host's log. Interruptions send nothing (a cancelled call) or are seen by the caller as a timeout.
- On the caller, the six protocol tags become their real classes. Other tags are decoded with `errors` when you pass it, and become `RemoteError` otherwise. A `RemoteError` keeps every field; read them with index access (`e["balance"]`, typed `unknown`). With `errors`, the runtime value is your class, but narrow with `instanceof` to get typed fields (see [Rpc.call](#rpccallname-input-options)).

See [Errors and gotchas](#errors-and-gotchas) for every tag in both languages.

### Tracing

- Every `Rpc.call` and `Rpc.callClient` runs in a span `rpc.client <name>` (kind `client`, attributes `rpc.name`, `rpc.target`). The request carries that span as a W3C `traceparent` in its `trace` field.
- The host runs the handler in a span `rpc.server <name>` (kind `server`, attributes `rpc.name`, `rpc.caller`) whose parent is the caller's span, so both halves share one trace id. A missing or malformed `trace` starts a new trace; it never rejects the request.
- This works in both directions and across languages: a Lua client's `Fx.rpc.call` continues into a TypeScript handler, and a TypeScript call continues into a Lua handler.
- The spans are ordinary Effect spans. To export them, provide an Effect tracer layer of your choice. The `/fxdev` devtools and the `rivo_fx` metrics and spans endpoints read Lua resources only; JS spans do not appear there, but the Lua half of a mixed trace does. See [Observability](#metrics-tracing-logs).

```ts
const order = Rpc.call("shop:buy", { item: "water" }, { timeout: 5_000 }).pipe(
  Effect.withSpan("shop.checkout")   // parent of rpc.client shop:buy, which is the parent of rpc.server shop:buy
)
```

### Bundling a resource

Bundle each side into one IIFE file with `effect` and `@rivolabs/fx` inside. The repository's
[examples/js_example/build.mjs](https://github.com/RivoLabs/rivo_fx/blob/main/examples/js_example/build.mjs) does this with esbuild (it
resolves `@rivolabs/fx` to the repo's `dist/`; in your own project, install the package instead).
A standalone version:

```js
// build.mjs: node build.mjs
import * as esbuild from "esbuild"

await Promise.all(["server", "client"].map((side) =>
  esbuild.build({
    entryPoints: [`src/${side}.ts`],
    outfile: `dist/${side}.js`,
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    mainFields: ["module", "main"],
    logLevel: "warning"
  })
))
```

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'

server_script 'dist/server.js'
client_script 'dist/client.js'
```

- `platform: "neutral"` keeps Node built-ins out. The client entry uses no Node APIs.
- `src/client.ts` must start with `import "@rivolabs/fx/polyfill"`.
- A JS resource does not need the `rivo_fx` Lua resource. It only talks to Lua resources over net events.
- Type-check each side with its own `tsconfig`: `@citizenfx/server` and `@citizenfx/client` declare conflicting globals.

### Interop with Lua

The JS package and the Lua library implement the same protocol, so:

- A Lua client calls a TypeScript server RPC with `Fx.rpc.call(name, input, { resource = '<js resource>' })`. A TypeScript client calls a Lua server RPC with `Rpc.call(name, input, { resource: "<lua resource>" })`. `resource` is required whenever the host is a different resource, because requests go to `__rfx:<target>:req` and the target defaults to the caller's own resource.
- The server side works the same way: Lua `Fx.rpc.callClient(src, name, input, { resource = ... })` reaches a JS client host, and JS `Rpc.callClient` reaches a Lua client host.
- Tagged errors cross both ways with their `_tag` and fields. A TypeScript `NotEnoughMoney { balance, wanted }` arrives in Lua as a table with `_tag = 'NotEnoughMoney'`, so `:catchTag('NotEnoughMoney', function(e) ... e.balance ... end)` works. A Lua `Fx.TaggedError('NotYours') { plate = 'ABC' }` arrives in TypeScript as `RemoteError` (or your class via `errors`).
- Protocol errors (`RpcTimeout`, `RpcInvalidInput`, ...) have the same tags and fields on both sides. `message` texts differ: Lua schema messages vs Effect `SchemaError` messages.
- Timeouts and cancellation cross too: a Lua caller that times out sends the cancel event and the TypeScript handler is interrupted.
- Net events are plain FiveM events with one payload argument on both sides, so `Fx.net.send('js_res:deposit', { amount = 100 })` reaches a JS `Net.handle`.
- Payload shapes: Lua has no `null` and no empty-array/empty-object distinction. An optional field set to `null` in JS is absent in Lua, and `{}` and `[]` are the same empty table. Use [`rivo-fx gen`](#cli) to keep schemas identical on both sides.

```lua
-- Lua client, calling the TypeScript server from examples/js_example
local JS = { resource = 'js_example', timeout = 5000 }
Fx.runFork(Fx.rpc.call('js_example:withdraw', { amount = 1000 }, JS)
  :catchTag('NotEnoughMoney', function(e)
    return Fx.succeed(('have %d, wanted %d'):format(e.balance, e.wanted))
  end))
```

<a id="cli"></a>

## CLI (rivo-fx)
`@rivolabs/fx-cli` installs the `rivo-fx` command. `rivo-fx create` writes a new Lua resource from
a template, and `rivo-fx gen` turns one JSON schema file into matching validators and types for
every side of a resource: Lua (`Fx.S` schemas with LuaLS classes), TypeScript Effect schemas for
[`@rivolabs/fx`](#javascript-typescript) resources, and plain TypeScript types for NUI pages. This page covers every
command, option, schema type, exit code and error message.

### Install and run

```sh
npx rivo-fx <command> ...                 # no install
pnpm add -D @rivolabs/fx-cli              # or pin it in a project, then: pnpm rivo-fx ...
```

- Needs Node 20 or newer.
- The package also exports `run`, `parseSpec`, `SpecError`, `generateLua`, `generateEffect` and `generateTypes` for use from scripts.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | success, `--help`/`-h`, or `gen --check` found every output up to date |
| `1` | any error, `rivo-fx` with no arguments (prints usage), or `gen --check` found a stale or missing output |

Messages go to stderr, except the usage text for `--help`/`-h` and no arguments (stdout) and the
`wrote <file>` / `created ...` lines (stdout).

### Commands

#### rivo-fx --help

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

#### rivo-fx create(dir, --template, --name)

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

##### Template lua

| File | What it does |
|---|---|
| `fxmanifest.lua` | `lua54 'yes'`, `dependency 'rivo_fx'`, shared scripts `@rivo_fx/init.lua` and `shared/schemas.lua` |
| `shared/schemas.json` | `Item` (literal `water`, `bread`, `phone`), `BuyInput { item, qty 1..10 }`, `Receipt { item, qty, paid, cash }` |
| `shared/schemas.lua` | generated from `schemas.json`: the global table `<Namespace>` with `Item`, `BuyInput`, `Receipt` |
| `server.lua` | `Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))` and `Fx.rpc.register('<name>:buy', { input, output, rateLimit = '5/s' }, ...)`, which charges cash with `removeMoney` (fails `InsufficientFunds`) |
| `client.lua` | command `/<name> <item> [qty]`: calls the RPC with a 5 s timeout and handles `InsufficientFunds` and `RpcInvalidInput` with `catchTag` |
| `.luarc.json` | LuaLS: Lua 5.4, `workspace.library` set to `../rivo_fx/types` |
| `README.md` | how to regenerate the schemas and start the resource |

##### Template lua-nui

Everything in `lua`, with these files replaced or added:

| File | What it does |
|---|---|
| `fxmanifest.lua` | adds `ui_page 'web/index.html'` and `files { 'web/index.html', 'web/app.js', 'web/fx-nui.js' }` |
| `client.lua` | command `/<name>` opens the page. `Fx.nui.handle('buy', ...)` forwards to the server RPC, so its tagged errors reach the page. `Fx.nui.handle('close', ...)` interrupts the fiber that holds `Fx.nui.useFocus()` |
| `web/index.html`, `web/app.js` | the page: `fetchNui('buy', ...)`, `isNuiError(e, 'InsufficientFunds')`, `onMessage('open', ...)`, and `mockNui` so it runs in a normal browser |
| `web/fx-nui.js` | a copy of the built `@rivolabs/fx-nui` |

The `README.md` from the `lua` template is kept, so it still describes the `/<name> <item> [qty]`
command of the plain template.

#### rivo-fx gen(schemas.json, --lua, --ts, --types, --namespace, --check)

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

### The schema file

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

#### Generated output

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

#### Schema file errors

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

### Where Lua and JS can still differ

The CLI's test suite runs one corpus of inputs through the generated Lua and the generated Effect
schemas and requires them to agree. Data that has no single meaning in both languages can still
differ:

- `null`: Lua has only `nil`, so an optional field set to `null` is absent in Lua but rejected by Effect.
- `{}` and `[]` are the same empty table in Lua.
- A struct in Lua drops unknown keys by default; Effect's `Schema.Struct` also strips them on decode. Both accept extra keys.

See [Schema](#schema) for `Fx.S` and [JS and TypeScript](#javascript-typescript) for using the Effect output.

<a id="recipes"></a>

## Recipes
Ten complete solutions to common FiveM tasks, written with the Rivo FX Lua API. Each one has a
one-line goal, the full code with the server, client and page parts labelled, and a few lines on
why it is built that way. Every resource below loads the library the usual way:

```lua
-- fxmanifest.lua (add your own scripts below)
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

For the API behind each call see [Effects](#effects), [Schema](#schema),
[Net and RPC](#net-events-and-rpc), [FiveM modules](#players-config-assets-entities), [Data](#kvp-state-database-frameworks), [NUI](#nui) and
[Observability](#metrics-tracing-logs). For the error tags see [Errors and gotchas](#errors-and-gotchas).

### 1. A validated shop purchase with a typed OutOfStock error shown in NUI

Goal: the page buys an item through the server, and an `OutOfStock` failure reaches the page as
its own tag with its fields.

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_scripts { '@rivo_fx/init.lua', 'shared.lua' }
server_script 'server.lua'
client_script 'client.lua'

ui_page 'web/index.html'
files { 'web/index.html', 'web/app.js', 'web/fx-nui.js' }
```

```lua
-- shared.lua
local S = Fx.S
ShopSchemas = {
  BuyInput = S.struct { item = S.enum { 'water', 'bread', 'phone' }, qty = S.int:between(1, 10) },
  Receipt = S.struct { item = S.string, qty = S.int, paid = S.int },
}
```

```lua
-- server.lua
local OutOfStock = Fx.TaggedError('OutOfStock')
local PRICES = { water = 5, bread = 8, phone = 450 }
local stock = { water = 20, bread = 5, phone = 0 }

-- Take qty from stock in one step, or fail with OutOfStock { item, left }.
local function reserve(item, qty)
  return Fx.suspend(function()
    local left = stock[item]
    if left < qty then return OutOfStock { item = item, left = left }:fail() end
    stock[item] = left - qty
    return Fx.unit
  end)
end

local function unreserve(item, qty)
  return Fx.sync(function() stock[item] = stock[item] + qty end)
end

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('shop:buy', { input = ShopSchemas.BuyInput, output = ShopSchemas.Receipt, rateLimit = '2/s' },
  function(src, input)
    return Fx.gen(function()
      local fw = Fx.yield(Fx.framework.Framework)
      local cost = PRICES[input.item] * input.qty
      -- InsufficientFunds puts the stock back; nothing interrupts between the two steps
      Fx.yield(reserve(input.item, input.qty)
        :zipRight(fw.removeMoney(src, 'cash', cost, 'shop purchase')
          :tapError(function() return unreserve(input.item, input.qty) end))
        :uninterruptible())
      return { item = input.item, qty = input.qty, paid = cost }
    end)
  end)
```

```lua
-- client.lua
local open -- the fiber that holds NUI focus while the page is open

-- The page's fetchNui('buy', ...) lands here; the server's tagged errors pass through to the page.
Fx.nui.handle('buy', { input = ShopSchemas.BuyInput }, function(input)
  return Fx.rpc.call('shop:buy', input, { timeout = 5000 })
end)

Fx.nui.handle('close', { input = Fx.S.struct {} }, function()
  if open then open:interruptAsFork(0) end
  return true
end)

RegisterCommand('shop', function()
  if open then return end
  open = Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.nui.useFocus())                                   -- released when this scope closes
    Fx.yield(Fx.nui.send('open', { items = { 'water', 'bread', 'phone' } }))
    Fx.yield(Fx.never)
  end)):ensuring(Fx.sync(function()
    open = nil
    SendNUIMessage({ type = 'close' })
  end)))
end, false)
```

```js
// web/app.js (page). web/fx-nui.js is the built @rivolabs/fx-nui; `rivo-fx create --template lua-nui` copies it in.
import { fetchNui, isNuiError, onMessage } from './fx-nui.js'

const status = document.getElementById('status')
const show = (text) => { status.textContent = text }

export async function buy(item, qty) {
  try {
    const r = await fetchNui('buy', { item, qty })
    show(`Bought ${r.qty}x ${r.item} for $${r.paid}`)
  } catch (e) {
    if (isNuiError(e, 'OutOfStock')) show(`Only ${e.fields.left} ${e.fields.item} left`)
    else if (isNuiError(e, 'InsufficientFunds')) show(`You need $${e.fields.need}, you have $${e.fields.have}`)
    else if (isNuiError(e, 'RpcInvalidInput')) show(`Check the order: ${e.fields.message}`)
    else if (isNuiError(e, 'RpcTimeout')) show('The shop did not answer')
    else show(`Something went wrong (${e._tag ?? e})`)
  }
}

onMessage('open', ({ items }) => { /* render one button per item that calls buy(item, qty) */ })
window.addEventListener('message', (e) => { if (e.data?.type === 'close') { /* hide the page */ } })
```

```html
<!-- web/index.html -->
<!doctype html>
<html>
  <body>
    <div id="status"></div>
    <script type="module" src="./app.js"></script>
  </body>
</html>
```

Why:
- The schema is checked twice on purpose: `Fx.nui.handle` stops a broken page before a network round trip, and `Fx.rpc.register` stops a cheating client. A failed server check is also reported to `Fx.security`.
- `reserve` checks and takes stock inside one `Fx.suspend`, so two buyers cannot both take the last item. `:uninterruptible()` covers a player who drops between taking stock and paying.
- The page branches on `e._tag` exactly as Lua code uses `:catchTag`. Defects would arrive as `RpcInternalError` with no details.

### 2. A money transfer with Fx.framework and an Fx.db.transaction

Goal: move bank money between two players on any framework, and record both sides in a ledger in
one database transaction.

```sql
-- once
CREATE TABLE bank_ledger (
  id INT AUTO_INCREMENT PRIMARY KEY,
  identifier VARCHAR(64) NOT NULL,
  delta INT NOT NULL,
  counterparty VARCHAR(64) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

```lua
-- fxmanifest.lua: dependencies { 'rivo_fx', 'oxmysql' }
-- server.lua
local S = Fx.S
local SameAccount = Fx.TaggedError('SameAccount')

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

local Transfer = S.struct { to = S.player, amount = S.int:between(1, 1000000) }
local LEDGER = 'INSERT INTO bank_ledger (identifier, delta, counterparty) VALUES (?, ?, ?)'

Fx.rpc.register('bank:transfer', { input = Transfer, rateLimit = '1/s' }, function(src, input)
  return Fx.gen(function()
    if input.to == src then return Fx.yield(SameAccount {}:fail()) end
    local fw = Fx.yield(Fx.framework.Framework)
    local from = Fx.yield(fw.getPlayer(src))
    local to = Fx.yield(fw.getPlayer(input.to))                  -- PlayerNotFound: no character loaded

    -- Take, then give; if giving fails, give the money back. No interruption in between.
    local balance = Fx.yield(fw.removeMoney(src, 'bank', input.amount, 'transfer to ' .. to.identifier)
      :zipLeft(fw.addMoney(input.to, 'bank', input.amount, 'transfer from ' .. from.identifier)
        :tapError(function() return fw.addMoney(src, 'bank', input.amount, 'transfer refund'):orDie() end))
      :uninterruptible())

    -- Both ledger rows or neither. The money has moved, so a ledger failure is logged, not returned.
    Fx.yield(Fx.db.transaction({
      { query = LEDGER, values = { from.identifier, -input.amount, to.identifier } },
      { query = LEDGER, values = { to.identifier, input.amount, from.identifier } },
    })
      :retry(Fx.Schedule.exponential(200):take(3))
      :catchTag('SqlError', function(e)
        return Fx.logError('ledger write failed', {
          message = e.message, from = from.identifier, to = to.identifier, amount = input.amount,
        })
      end))

    return { balance = balance }
  end)
end)
```

```lua
-- client.lua: /transfer <player id> <amount>
RegisterCommand('transfer', function(_, args)
  local to, amount = tonumber(args[1]), tonumber(args[2])
  Fx.runFork(Fx.rpc.call('bank:transfer', { to = to, amount = amount }, { timeout = 5000 })
    :tap(function(r) print(('sent; your bank balance is $%d'):format(r.balance)) end)
    :catchTags {
      InsufficientFunds = function(e) print(('you need $%d, you have $%d'):format(e.need, e.have)) return Fx.unit end,
      PlayerNotFound = function() print('that player has no character loaded') return Fx.unit end,
      SameAccount = function() print('you cannot send money to yourself') return Fx.unit end,
      RpcInvalidInput = function(e) print('bad transfer: ' .. e.message) return Fx.unit end,
      RpcTimeout = function() print('the bank did not answer') return Fx.unit end,
    })
end, false)
```

Why:
- On ESX, QBCore and Qbox the framework owns the balance in memory and saves it itself, so money moves through `Fx.framework`, never through SQL. The database holds the ledger, and `Fx.db.transaction` makes its two rows atomic.
- `removeMoney` fails with `InsufficientFunds { need, have }` instead of going negative. `S.player` rejects ids of players who are not connected before the handler runs.
- The refund runs only if the deposit fails, and `:orDie()` turns a failed refund into a logged defect (the client gets `RpcInternalError`) rather than a silent loss.

### 3. A vehicle that is deleted when the player drops

Goal: spawn a server-side vehicle for a player and have it deleted automatically when that player
leaves (or the resource stops).

```lua
-- server.lua
local S = Fx.S
local Spawn = S.struct { model = S.enum { 'adder', 'sultan', 'faggio' } }

Fx.rpc.register('garage:spawn', { input = Spawn, rateLimit = '1/s' }, function(src, input)
  return Fx.gen(function()
    local ped = GetPlayerPed(src)
    -- spawnVehicle needs a Scope; the player's scope closes on playerDropped and deletes it
    local veh = Fx.yield(Fx.player.extend(src,
      Fx.entity.spawnVehicle(input.model, GetEntityCoords(ped), GetEntityHeading(ped), { timeout = 5000 })))
    return NetworkGetNetworkIdFromEntity(veh)
  end)
end)
```

```lua
-- client.lua: /car [model]
RegisterCommand('car', function(_, args)
  Fx.runFork(Fx.gen(function()
    local netId = Fx.yield(Fx.rpc.call('garage:spawn', { model = args[1] or 'adder' }, { timeout = 8000 }))
    local veh = Fx.yield(Fx.entity.fromNetId(netId, { timeout = 5000 }))
    TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
  end):catchTags {
    RpcInvalidInput = function(e) print('unknown model: ' .. e.message) return Fx.unit end,
    SpawnFailed = function() print('the vehicle did not spawn') return Fx.unit end,
    NetIdTimeout = function() print('the vehicle never reached this client') return Fx.unit end,
  })
end, false)
```

Why:
- `Fx.entity.spawnVehicle` acquires the entity with a release that deletes it. `Fx.player.extend(src, eff)` runs it in the player's scope, so the release runs on `playerDropped`, and every open scope also closes on resource stop.
- The server owns the entity, so a client cannot keep it alive or spawn models outside the `S.enum` list.
- The client waits for the network id with a timeout instead of looping on `NetworkDoesNetworkIdExist`.

### 4. Security events batched to a Discord webhook

Goal: post rejected payloads and unknown RPCs to a Discord channel, at most one message per batch of
20 or per 10 seconds.

```lua
-- server.lua; server.cfg: set anticheat:webhook "https://discord.com/api/webhooks/..."
local WebhookFailed = Fx.TaggedError('WebhookFailed')

local function line(ev)
  local msg = ev.message and (': ' .. tostring(ev.message):sub(1, 120)) or ''
  return ('`%s` player %s on `%s`%s'):format(ev.kind, tostring(ev.source), tostring(ev.name), msg)
end

local function post(url, batch)
  local lines = {}
  for i, ev in ipairs(batch) do lines[i] = line(ev) end
  return Fx.async(function(resume)
    PerformHttpRequest(url, function(status)
      if status >= 200 and status < 300 then resume(Fx.unit)
      else resume(Fx.fail(WebhookFailed { status = status })) end
    end, 'POST', json.encode({ content = table.concat(lines, '\n') }), { ['Content-Type'] = 'application/json' })
  end)
end

Fx.runFork(Fx.gen(function()
  local url = Fx.yield(Fx.config.string('anticheat:webhook'))   -- ConfigError when unset
  Fx.yield(Fx.security.stream()
    :filter(function(ev) return ev.kind ~= 'rate_limited' end)
    :groupedWithin(20, 10000)
    :runForEach(function(batch)
      return post(url, batch):timeout(5000):catchAll(function(e)
        return Fx.logWarn('webhook post failed', { error = e._tag, status = e.status })
      end)
    end))
end))
```

Why:
- `groupedWithin(20, 10000)` emits a batch when 20 events have piled up, or 10 s after the first event of a batch, whichever comes first, so a flood becomes a few posts instead of hundreds.
- `runForEach` handles one batch at a time. While a post is in flight, new events wait in the stream's buffer (1024 by default, oldest dropped first). Rate-limit hits are filtered out because a flood produces one per message.
- `Fx.security.stream()` sees this resource's events only. To watch every resource, stream the local event instead: `Fx.Stream.event('rivo_fx:security', function(ev, resource) ev.resource = resource return ev end)`.

### 5. A retrying external HTTP call with a timeout

Goal: fetch JSON from an external API, give each attempt 3 s, retry server errors and timeouts with
exponential backoff, and decode the body with a schema.

```lua
-- server.lua
local S = Fx.S
local HttpError = Fx.TaggedError('HttpError')
local Price = S.struct { usd = S.number }

local function httpGet(url)
  return Fx.async(function(resume)
    PerformHttpRequest(url, function(status, body)
      if status >= 200 and status < 300 then resume(Fx.succeed(body))
      else resume(Fx.fail(HttpError { url = url, status = status })) end
    end, 'GET', '', { Accept = 'application/json' })
  end)
end

-- Retry timeouts and anything but a 4xx (429 Too Many Requests is retried).
local function retryable(e)
  if e._tag == 'TimeoutError' then return true end
  if e._tag ~= 'HttpError' then return false end
  return e.status == 429 or e.status < 400 or e.status >= 500
end

local function fetchPrice()
  return httpGet('https://api.example.com/price')
    :timeout(3000)                                                       -- TimeoutError { timeoutMs }
    :retry(Fx.Schedule.exponential(250):jittered():whileInput(retryable):take(4))
    :flatMap(function(body)
      local ok, decoded = pcall(json.decode, body)
      return Price:decode(ok and decoded or nil)                         -- ParseError { message }
    end)
end

RegisterCommand('price', function()
  Fx.runFork(fetchPrice()
    :tap(function(p) print(('price: $%.2f'):format(p.usd)) end)
    :catchAll(function(e) return Fx.logWarn('price lookup failed', { error = Fx.inspect(e) }) end))
end, true)
```

Why:
- `:timeout(3000)` sits inside `:retry(...)`, so each attempt gets its own 3 s, and a timeout is just another failure the schedule can retry. Put a second `:timeout` outside the retry to cap the total.
- The schedule reads as written: delays of about 250, 500, 1000 and 2000 ms (randomised by 0.8 to 1.2), only while the error is retryable, at most 4 retries. After that the last error is returned.
- `PerformHttpRequest` cannot be aborted. When an attempt times out, its late callback is ignored, so it can never resume the next attempt.

### 6. A per-player cooldown

Goal: let each player claim a reward once every 30 minutes, and tell them how long to wait.

```lua
-- server.lua
local S = Fx.S
local OnCooldown = Fx.TaggedError('OnCooldown')
local lastUsed = {} -- src -> GetGameTimer() of the last claim
local watched = {}  -- src -> true once an onDrop cleanup is registered

---Run eff unless src ran it less than ms ago. A failed eff does not use up the cooldown.
local function cooldown(src, ms, eff)
  return Fx.suspend(function()
    local now, last = GetGameTimer(), lastUsed[src]
    if last and now - last < ms then
      return OnCooldown { remainingMs = ms - (now - last) }:fail()
    end
    if not watched[src] then
      watched[src] = true
      Fx.player.onDrop(src, function() lastUsed[src], watched[src] = nil, nil end)
    end
    lastUsed[src] = now
    return eff:tapError(function() return Fx.sync(function() lastUsed[src] = last end) end)
  end)
end

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('reward:claim', { input = S.struct {} }, function(src)
  return cooldown(src, 30 * 60 * 1000, Fx.gen(function()
    local fw = Fx.yield(Fx.framework.Framework)
    return Fx.yield(fw.addMoney(src, 'cash', 250, 'reward'))
  end))
end)
```

```lua
-- client.lua
RegisterCommand('reward', function()
  Fx.runFork(Fx.rpc.call('reward:claim', {}, { timeout = 5000 })
    :tap(function(cash) print(('+$250, cash now $%d'):format(cash)) end)
    :catchTag('OnCooldown', function(e)
      print(('come back in %d minutes'):format(math.ceil(e.remainingMs / 60000)))
      return Fx.unit
    end))
end, false)
```

Why:
- The check and the update happen in one `Fx.suspend`, so two requests in the same frame cannot both pass.
- A cooldown is a game rule the player should see, so it is a tagged error with `remainingMs`. The RPC's `rateLimit` (10/s by default) is a different thing: it protects the server from floods and reports `rate_limited` security events.
- `Fx.player.onDrop` forgets the timer when the player leaves, so the table does not grow.

### 7. A proximity marker with Fx.tick.whileNear

Goal: draw a marker and a help prompt near a shop, paying for per-frame work only while the player
is close.

```lua
-- client.lua
local SHOP = vector3(25.7, -1347.3, 29.5)
local marker

local function drawShop(distance)
  DrawMarker(1, SHOP.x, SHOP.y, SHOP.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.5, 1.5, 0.5,
    30, 144, 255, 120, false, false, 2, false, nil, nil, false)
  if distance < 1.5 then
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to shop')
    EndTextCommandDisplayHelp(0, false, true, -1)
    if IsControlJustReleased(0, 38) then ExecuteCommand('shop') end
  end
end

local function start()
  marker = Fx.runFork(Fx.tick.whileNear(SHOP, 15.0, drawShop, { checkMs = 1000 }))
end

-- /shopmarker toggles it, to show that stopping is one call
RegisterCommand('shopmarker', function()
  if marker then
    marker:interruptAsFork(0)
    marker = nil
  else
    start()
  end
end, false)

start()
```

Why:
- While the player is farther than 15 m, the distance is checked once a second (`checkMs`), so the marker costs almost nothing away from the shop. Within range, `drawShop` runs every frame with the current distance.
- The loop is a fiber: interrupting it, or the resource stopping, ends the frame thread. There is no `while true do Wait(0) end` to forget about.
- If `drawShop` raises, the effect fails with that defect and the error is logged as an unhandled fiber failure (visible in `/fxdev` Failures) instead of silently killing a thread.

### 8. A service provided by a Layer and swapped in tests

Goal: put payment behind a `Bank` service, use the framework in production, and test the purchase
logic with a fake bank.

```lua
-- server.lua
local S = Fx.S
Bank = Fx.Tag('Bank')
NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

-- Production: Bank on top of the running framework.
local BankLive = Fx.Layer.effect(Bank, Fx.gen(function()
  local fw = Fx.yield(Fx.framework.Framework)
  return {
    pay = function(src, amount, reason)
      return fw.removeMoney(src, 'bank', amount, reason):asVoid()
        :catchTag('InsufficientFunds', function(e)
          return NotEnoughMoney { have = e.have, need = e.need }:fail()
        end)
    end,
  }
end)):provide(Fx.framework.auto)

-- The logic only knows about Bank.
function BuyLicense(src)
  return Fx.gen(function()
    local bank = Fx.yield(Bank)
    Fx.yield(bank.pay(src, 500, 'weapon license'))
    return true
  end)
end

Fx.setRuntime(Fx.Runtime.make(BankLive))
Fx.rpc.register('license:buy', { input = S.struct {} }, function(src) return BuyLicense(src) end)
```

```lua
-- server_test.lua: load it only on a dev server (server_script 'server_test.lua' after server.lua)
local function FakeBank(balance)
  local paid = {}
  local layer = Fx.Layer.succeed(Bank, {
    pay = function(_, amount)
      return Fx.suspend(function()
        if amount > balance then return NotEnoughMoney { have = balance, need = amount }:fail() end
        balance = balance - amount
        paid[#paid + 1] = amount
        return Fx.unit
      end)
    end,
  })
  return layer, paid
end

RegisterCommand('test_license', function()
  CreateThread(function()
    local rich, paid = FakeBank(1000)
    assert(Fx.runAwait(BuyLicense(1):provide(rich)) == true)
    assert(paid[1] == 500, 'charged 500')

    local poor = FakeBank(100)
    local exit = Fx.runAwait(BuyLicense(1):provide(poor):exit())
    assert(Fx.Cause.failureOption(exit.cause)._tag == 'NotEnoughMoney')
    print('license tests passed')
  end)
end, true)
```

Why:
- `Fx.yield(Bank)` asks for whatever implementation is provided. The RPC gets `BankLive` from `Fx.setRuntime`; the test gets `FakeBank` from `:provide(layer)`. `BuyLicense` does not change.
- `BankLive` maps the framework's `InsufficientFunds` to the service's own `NotEnoughMoney`, so callers and tests depend on one error, whatever the framework.
- `Fx.runAwait` raises on failure, so the second case uses `:exit()` to inspect the failure as a value. A missing service is a defect: `Service not found: Bank. Provide it with :provide(layer) or :provideService(tag, impl).`

### 9. Tracing an RPC and reading it in /fxdev

Goal: see one trace from a client command through the server handler, with timings, attributes
and the log lines that belong to it.

```cfg
## server.cfg
ensure rivo_fx
ensure bank
add_ace group.admin rivo_fx.devtools allow
add_principal identifier.license:your_license_here group.admin
```

```lua
-- server.lua
local S = Fx.S
local Lookup = Fx.metrics.histogram('bank_lookup_ms', { help = 'Balance lookups', buckets = { 1, 5, 25, 100 } })

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('bank:balance', { input = S.struct { account = S.enum { 'cash', 'bank' } } }, function(src, input)
  return Fx.gen(function()
    Fx.yield(Fx.annotateCurrentSpan('account', input.account))       -- on the rpc.server span
    local fw = Fx.yield(Fx.framework.Framework)
    local balance = Fx.yield(fw.getMoney(src, input.account):withSpan('framework.getMoney'))
    Fx.yield(Fx.logInfo('balance read', { account = input.account })) -- logged with traceId and spanId
    return balance
  end):trackDuration(Lookup)
end)
```

```lua
-- client.lua
RegisterCommand('balance', function()
  Fx.runFork(Fx.rpc.call('bank:balance', { account = 'bank' }, { timeout = 5000 })
    :tap(function(balance) print('bank balance', balance) end)
    :withSpan('ui.balance', { attributes = { source = 'command' } }))
end, false)
```

In game, run `/balance`, then `/fxdev traces`. The Traces view shows one trace as a waterfall,
roughly:

```
ui.balance                     client  bank
  rpc.client bank:balance      client  bank   rpc.name, rpc.target
    rpc.server bank:balance    server  bank   rpc.name, rpc.caller, player, account
      framework.getMoney       server  bank
```

Why:
- `Fx.rpc.call` sends its span as a W3C traceparent, and the server handler's `rpc.server` span continues it, so both sides share one trace id. A JS resource on either end joins the same trace, but only Lua resources show up in `/fxdev`.
- `/fxdev` asks the server for data only while it is open, and the server checks the `rivo_fx.devtools` ACE on every request. The `Fx.logInfo` line carries `traceId` and `spanId`. If the handler fails, its `rpc.server` span is marked as an error with the tag, and a defect is also logged to the Failures view.
- The client and server clocks are separate. When a span from one side falls outside its parent from the other, the waterfall moves it inside the parent and marks it with `~`. Use the `rpc.client` span (or `rivo_fx_rpc_call_ms`) for round-trip time, not start times compared across sides.

### 10. Moving an ox_lib callback without breaking old callers

Goal: move a `lib.callback.register` handler to `Fx.rpc.register` while old
`lib.callback.await` callers keep working, then move the callers one by one.

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependencies { 'ox_lib', 'rivo_fx' }
shared_scripts { '@ox_lib/init.lua', '@rivo_fx/init.lua' }
server_script 'server.lua'
client_script 'client.lua'
```

```lua
-- server.lua
-- before:
--   lib.callback.register('garage:list', function(source, kind) return listVehicles(source, kind) end)
local S = Fx.S
local garages = {} -- src -> { { plate, model, kind } }

Fx.rpc.register('garage:list', {
  input = S.enum { 'car', 'boat' },          -- old callers pass the kind as their first argument
  output = S.array(S.struct { plate = S.string, model = S.string, kind = S.string }),
  rateLimit = '5/s',
  libCallback = true,                        -- also answer lib.callback callers
}, function(src, kind)
  local out = {}
  for _, v in ipairs(garages[src] or {}) do
    if v.kind == kind then out[#out + 1] = v end
  end
  return out
end)
```

```lua
-- client.lua
-- An old caller, unchanged: still validated and rate limited.
RegisterCommand('cars_old', function()
  local cars = lib.callback.await('garage:list', false, 'car')
  print('cars (old):', cars and #cars or 'rejected')
end, false)

-- A moved caller: a timeout and typed errors.
RegisterCommand('cars', function()
  Fx.runFork(Fx.rpc.call('garage:list', 'car', { timeout = 5000 })
    :tap(function(cars) print('cars:', #cars) end)
    :catchTags {
      RpcInvalidInput = function(e) print('bad request: ' .. e.message) return Fx.unit end,
      RpcTimeout = function() print('the garage did not answer') return Fx.unit end,
    })
end, false)

-- A callback that still lives in ox_lib, called from Fx.
RegisterCommand('impound', function()
  Fx.runFork(Fx.compat.libCallback('impound:list', 'car', Fx.compat.opts { timeout = 3000 })
    :tap(function(list) print('impounded:', list and #list or 0) end)
    :catchTag('RpcTimeout', function() print('impound did not answer') return Fx.unit end))
end, false)
```

Why:
- With `libCallback = true` the same handler serves both protocols, with the same schema and the same rate-limit bucket. Old callers get `nil` when their input is rejected (and the server logs a security event); new callers get `RpcInvalidInput`.
- An ox_lib callback receives only its first argument as the input. If old callers pass several positional arguments, keep a wrapper until they are moved, or change them to pass one table.
- Once no `lib.callback.await('garage:list', ...)` remains, delete `libCallback = true`. `Fx.compat.libCallback` covers the other direction: calling a handler that has not moved yet, with a timeout that fails `RpcTimeout`.

<a id="errors-and-gotchas"></a>

## Errors and gotchas
This page lists every error tag the Rivo FX Lua library and the JS packages produce, with the
module it comes from, when it happens, its fields and how to handle it. It then explains the three
ways an effect can end badly (failures, defects and interruptions), and closes with common mistakes
and their fixes, each taken from what the code actually does.

### Error tags

All tags below are expected failures (the `E` channel), so `:catchTag(tag, fn)` in Lua and
`Effect.catchTag(tag, fn)` in TypeScript handle them. Fields are the keys on the error value. Tags
marked "wire only" are never raised as a Lua failure; they appear only in a response sent to a
caller or a page.

#### Lua core

| Tag | Module | When | Fields | How to handle |
|---|---|---|---|---|
| `TimeoutError` | `Fx.TimeoutError` (`eff:timeout(ms)`) | the effect took longer than `ms`; it is interrupted | `timeoutMs` | `:catchTag('TimeoutError', ...)`, retry it, or use `:timeoutOption(ms)` (succeeds with `nil`) or `:timeoutFail(ms, fn)` (your own error) |
| `NoSuchElementError` | `Fx.NoSuchElementError` (`Fx.fromNullable(v)`) | `v` is `nil` and no `onNil` was given | none | pass `onNil` to fail with your own error |
| `UnknownError` | `Fx.UnknownError` (`Fx.try(fn)`) | `fn` raised something that is not a tagged error, and no `onError` was given | `message` (the `tostring` of what was raised), `cause` (the raised value) | pass `onError` to map it to your own tagged error |
| `ParseError` | `Fx.ParseError` (`schema:decode(v)`, `schema:parse(v)`) | `v` fails the schema. `decode` fails the effect; `parse` raises it | `message` (the schema message, for example `qty: must be between 1 and 10`) | catch it, or use `schema:validate(v)` to get `ok, valueOrMessage` without an error |
| `Interrupted` | `Fx.runAwait`, `Fx.runSync` | the effect was interrupted; this is what they raise. Not a declared class: a plain table | `_fxCause` (the cause) | `pcall(Fx.runAwait, eff)` and check `err._tag == 'Interrupted'` |

#### Lua FiveM modules

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

#### JS: @rivolabs/fx

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

See [JS and TypeScript](#error-classes) for the class signatures.

#### JS: @rivolabs/fx-nui (the page)

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

### Failures, defects and interruptions

An effect that does not succeed ends with a cause of one of three kinds:

- **Failure**: an expected error, the `E` in `Effect<A, E>`. Raised with `Fx.fail(e)`, `MyError { ... }:fail()`, or `error(MyError { ... })` inside `Fx.gen`/`Fx.sync`. `:catchAll`, `:catchTag`, `:catchTags`, `:mapError`, `:retry` and `:result` see failures only. Tagged failures cross RPC and NUI with their `_tag` and fields.
- **Defect**: a bug. Raised with `Fx.die(x)`, by any other `error(...)`, a nil index, a failed `spec.output`, or `:orDie()`. `:catchAll` does not catch it; `:catchAllDefect` and `:catchAllCause` do. A defect never crosses the wire: callers get `RpcInternalError { name }` and pages get `NuiInternalError { name }`, and the details are logged where it happened. A cause that holds both a failure and a defect counts as a defect.
- **Interruption**: the fiber was stopped from outside: a timeout, a cancelled RPC, a dropped player, a closed scope, a stopped resource, `fiber:interrupt()`. It is not an error. Finalizers (`:ensuring`, `:onInterrupt`, `Fx.acquireRelease`) still run, nothing catches it, an interrupted RPC handler sends no response, and fibers that end interrupted are not logged as unhandled failures.

`Fx.Cause.failures(c)`, `Fx.Cause.defects(c)`, `Fx.Cause.isInterruptedOnly(c)` and
`Fx.Cause.pretty(c)` take a cause apart. In TypeScript the same split is Effect's
`Cause` (`Cause.hasDies`, `Cause.hasInterruptsOnly`). See [Errors](#errors-and-causes).

### Common mistakes

#### Calling Fx.yield outside Fx.gen

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

#### Forgetting a schema on Fx.net.handle or Fx.rpc.register

```lua
Fx.net.handle('shop:buy', function(src, input) end)
-- raises at registration: Fx.net.handle("shop:buy"): a schema is required (use Fx.S.unknown to skip validation on purpose)
Fx.rpc.register('shop:buy', {}, handler)
-- raises: Fx.rpc.register("shop:buy"): spec.input schema is required (use Fx.S.unknown to skip validation on purpose)
```

Pass a schema, or `Fx.S.unknown` to accept anything on purpose. `Fx.net.stream` raises the same
way, and `Fx.nui.handle` asserts `spec.input (a schema) is required`. In TypeScript the schema is a
required parameter, so it is a type error.

#### Sending positional arguments instead of one table

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

#### Using Wait instead of Fx.sleep in fibers

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

#### Expecting a defect's details on the client

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

#### Label explosion in metrics

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

#### The rivo_fx resource not started first

```
rivo_fx: cannot load lib/core/platform.lua (is rivo_fx started and up to date?)
```

`@rivo_fx/init.lua` reads the library from the `rivo_fx` resource at load time. Fix all of:

- the folder is named exactly `rivo_fx`;
- `server.cfg` has `ensure rivo_fx` before every resource that uses it;
- each resource's `fxmanifest.lua` has `dependency 'rivo_fx'`, `lua54 'yes'` and `shared_script '@rivo_fx/init.lua'` (before scripts that use `Fx`);
- after updating Rivo FX, restart `rivo_fx` and then the resources that use it.

JS resources using `@rivolabs/fx` do not need the `rivo_fx` resource.

#### server.cfg ACE for /fxdev

Without permission, `/fxdev` prints
`/fxdev needs the rivo_fx.devtools permission (add_ace group.admin rivo_fx.devtools allow)` and
closes. The server checks the ACE on every request.

```cfg
add_ace group.admin rivo_fx.devtools allow
add_principal identifier.license:your_license_here group.admin
```

Spans and failures can hold player ids and error details, so grant it only to people who can read
the server console. JS resources do not appear in `/fxdev`.

#### Clocks differing between client and server spans

Each side stamps spans with its own clock (Unix time anchored once, then a monotonic timer), and a
player's PC can be seconds away from the server. `/fxdev` compares times from each side with that
side's own "now", and in the waterfall a span that falls outside its parent from another clock is
moved inside the parent and marked `~`. Do not subtract a client timestamp from a server
timestamp. Measure round trips on one side: the `rpc.client` span's duration or the
`rivo_fx_rpc_call_ms` histogram (caller side), and handler time with `rivo_fx_rpc_handler_ms`
(host side).

#### Calling an RPC in another resource without `resource`

Requests go to `__rfx:<target>:req`, and the target defaults to the caller's own resource.

```lua
Fx.rpc.call('garage:list', 'car')                                   -- goes to this resource
Fx.rpc.call('garage:list', 'car', { resource = 'garage', timeout = 5000 })   -- goes to 'garage'
```

Without it you get `RpcNotFound` (and an `unknown_rpc` security event against your own player) if
your resource hosts RPCs, or `RpcTimeout` if it does not.

#### Handlers that need a service but no runtime

```
Service not found: rivo_fx/Framework. Provide it with :provide(layer) or :provideService(tag, impl).
```

A net or RPC handler that does `Fx.yield(Fx.framework.Framework)` (or any `Fx.Tag`) needs the
service provided. Call `Fx.setRuntime(Fx.Runtime.make(layer))` once, before the handlers run, or
pass `runtime = rt` in the handler options, or `:provide(layer)` on the effect. In TypeScript, use
`Layer.provideMerge(FxServer.layer)` so `runtime.runFork` can see the services; with
`Layer.provide` the compiler reports the missing service.

#### Raising a plain error instead of a tagged one

Inside `Fx.gen` and `Fx.sync`, `error(NotFound { id = 1 })` is a failure, but `error('not found')`
is a defect: it skips `:catchAll`/`:catchTag` and reaches callers as `RpcInternalError`. Use
`NotFound { id = 1 }:fail()` (or `Fx.yield(NotFound { ... }:fail())` inside a gen) for anything
the caller should handle.

#### Side-specific functions

`Fx.rpc.call` exists only on clients and `Fx.rpc.callClient` only on servers; calling the other
one is `attempt to call a nil value`. `Fx.net.send` takes `(name, target, payload)` on the server
and `(name, payload)` on the client. Server-side `Fx.net.handle` ignores events with no player
`source`, so a local `TriggerEvent(name, ...)` from another server script does not reach it.

#### Running async effects with Fx.runSync

`Fx.runSync` runs right now and cannot wait. Anything that sleeps, waits for a callback or calls
the network dies with `Fx.runSync hit an async effect. Use Fx.runFork or Fx.runAwait instead.`
Use `Fx.runFork` (fire and forget, failures logged) or `Fx.runAwait` (block the current Citizen
thread and get the value).

#### `while` and `until` in a retry policy

`eff:retry { times = 3, while = fn }` is a Lua syntax error (`unexpected symbol near 'while'`):
both are keywords. Write `['while'] = fn` / `['until'] = fn`, or use a schedule:
`eff:retry(Fx.Schedule.spaced(500):whileInput(fn):take(3))`.

#### Empty convars

Lua `Fx.config` treats a convar set to `""` as unset (default or `ConfigError`). The JS
`Config.convarProvider` treats it as the value `""`. Use `setr`/`set` with a real value, or a
default on both sides.

#### Forgetting the polyfill in a JS client

A client bundle without `import "@rivolabs/fx/polyfill"` as its first import fails at load with
`TextEncoder is not defined`. Importing `@rivolabs/fx/client` first is not enough: the built file
imports `effect` before its own copy of the polyfill runs. See [JS and TypeScript](#why-the-polyfill-exists).

<a id="migrating"></a>

## Moving a resource to Rivo FX
You do not have to rewrite anything up front. Rivo FX runs next to plain
Citizen code, `Fx.runAwait` works from any thread, and the ox_lib bridge keeps
old callers working while you move handlers over. Pick the pattern that hurts
most and start there.

Every "after" below assumes the resource loads Rivo FX:

```lua
dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

### Net events you validate by hand

Before: every handler re-checks its arguments (or forgets to), and nothing stops
a client from firing it 500 times a second.

```lua
RegisterNetEvent('shop:buy', function(item, qty)
  local src = source
  if type(item) ~= 'string' or type(qty) ~= 'number' or qty < 1 or qty > 10 then return end
  -- ...
end)
```

After: the schema runs first, the handler only sees clean input, each player is
rate limited, and rejected payloads are reported to `Fx.security.on`.

```lua
local S = Fx.S
Fx.net.handle('shop:buy', S.struct { item = S.string:maxChars(32), qty = S.int:between(1, 10) },
  function(src, input)
    -- input.item and input.qty are checked; unknown fields are dropped
  end, { rateLimit = '5/s' })
```

Clients send a table: `TriggerServerEvent('shop:buy', { item = 'water', qty = 2 })`
or `Fx.net.send('shop:buy', { ... })`.

### ox_lib callbacks

Before:

```lua
-- server
lib.callback.register('bank:balance', function(src, account) return getBalance(src, account) end)
-- client
local balance = lib.callback.await('bank:balance', false, 'main')
```

After: register the handler with Rivo FX and keep `libCallback = true` until
every caller is moved. Old `lib.callback.await` callers keep working (still
validated and rate limited), new callers get typed errors and timeouts.

```lua
-- server
Fx.rpc.register('bank:balance', { input = S.string, libCallback = true }, function(src, account)
  return Bank.balance(src, account) -- a value or an effect
end)
-- client, new style
local balance = Fx.yield(Fx.rpc.call('bank:balance', 'main', { timeout = 5000 }))
```

Calling a callback that still lives in ox_lib, from Rivo FX:
`Fx.compat.libCallback('other:thing', arg1, arg2, Fx.compat.opts { timeout = 3000 })`.

### ESX and QBCore callbacks

`ESX.RegisterServerCallback` and `QBCore.Functions.CreateCallback` hand you a
`cb` that the client waits on forever if the server errors. Replace them with
`Fx.rpc.register`; a failure reaches the caller as its tag, and the caller's
timeout always fires.

```lua
-- before
QBCore.Functions.CreateCallback('garage:spawn', function(src, cb, plate)
  local veh = spawn(plate)
  cb(veh ~= nil)
end)

-- after
local NotYours = Fx.TaggedError('NotYours')
Fx.rpc.register('garage:spawn', { input = S.string:maxChars(8) }, function(src, plate)
  if not owns(src, plate) then return NotYours { plate = plate }:fail() end
  return spawn(plate)
end)

-- client
Fx.rpc.call('garage:spawn', plate, { timeout = 5000 })
  :catchTag('NotYours', function() return Fx.succeed(nil) end)
```

### Money and jobs through the framework

Before: one code path per framework, and a failed removal is a `false` you have
to remember to check.

```lua
local Player = QBCore.Functions.GetPlayer(src)
if not Player.Functions.RemoveMoney('bank', 500, 'garage') then return end
```

After: one service for ESX, QBCore, Qbox and standalone. `removeMoney` fails
with `InsufficientFunds { need, have }` and never goes negative.

```lua
Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

local fw = Fx.yield(Fx.framework.Framework)
Fx.yield(fw.removeMoney(src, 'bank', 500, 'garage'))
fw.onPlayerLoaded(function(src) ... end)   -- fires once per character, on every framework
```

### oxmysql

Before: `MySQL.query.await` returns rows of whatever shape the table has today,
and a failed query is a printed error and a `nil`.

```lua
local rows = MySQL.query.await('SELECT id, money FROM players WHERE id = ?', { id })
```

After: rows are checked against a schema, and every failure is an `SqlError`
you can catch, retry or map.

```lua
local Row = S.struct { id = S.int, money = S.int }
local rows = Fx.yield(Fx.db.query('SELECT id, money FROM players WHERE id = ?', { id }, { row = Row })
  :retry(Fx.Schedule.exponential(100):take(3)))
```

### Loading models and dictionaries

```lua
-- before
RequestModel(model)
while not HasModelLoaded(model) do Wait(0) end   -- forever, if the model is wrong

-- after
local hash = Fx.yield(Fx.assets.model('adder', { timeout = 5000 }))   -- AssetNotFound / AssetTimeout
-- or released automatically when the scope closes:
Fx.yield(Fx.assets.useModel('adder'))
```

### Threads and loops

```lua
-- before: runs forever, even after you no longer need it
CreateThread(function()
  while true do
    Wait(0)
    if #(GetEntityCoords(PlayerPedId()) - shop) < 10.0 then DrawMarker(...) end
  end
end)

-- after: checks distance every 500 ms while away, runs every frame only when
-- close, and stops when the fiber is interrupted or its scope closes
local marker = Fx.runFork(Fx.tick.whileNear(shop, 10.0, function() DrawMarker(...) end))
marker:interruptAsFork(0) -- when you are done
```

Repeating work: `Fx.yield(Fx.sleep(1000))` inside a fiber instead of `Wait`.
A sleeping fiber costs nothing, and it can be interrupted while it sleeps.

### NUI

Before: `RegisterNUICallback` answers whatever you hand `cb`, and the page's
`fetch` never learns about an error.

After, in the client script:

```lua
Fx.nui.handle('buy', { input = S.struct { item = S.string, qty = S.int:between(1, 10) } }, function(input)
  return Fx.rpc.call('shop:buy', input)   -- the server's tagged errors reach the page
end)
```

and in the page, with [`@rivolabs/fx-nui`](https://github.com/RivoLabs/rivo_fx/blob/main/packages/fx-nui):

```ts
try {
  const receipt = await fetchNui("buy", { item, qty })
} catch (e) {
  if (isNuiError(e, "InsufficientFunds")) showBroke(e.fields.need)
}
```

### Keeping shapes in sync

Once a payload is shared by Lua, a JS resource and a page, describe it once and
generate all three with [`rivo-fx gen`](https://github.com/RivoLabs/rivo_fx/blob/main/packages/cli).

### Calling Rivo FX from old code

Anything that is still a plain thread can use an effect directly:

```lua
CreateThread(function()
  local ok, hash = pcall(Fx.runAwait, Fx.assets.model('adder', { timeout = 5000 }))
end)
```
