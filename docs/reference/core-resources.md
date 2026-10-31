# Core resources and services

This page covers resource safety (scopes, finalizers, `acquireRelease`, resource-stop cleanup) and dependency injection (service tags, Layers, Runtimes). Use scopes for anything that must be undone: spawned entities, loaded models, focus, event handlers, background loops. Use tags and layers to give handlers their dependencies (a bank, a database, a framework adapter) without globals, and to swap them in tests.

Examples print values with a `--> result` comment showing what they print.

## Finalizers on one effect

These run a finalizer after an effect however it ends. Finalizers run uninterruptibly. Every callback must return an effect (`Fx.unit` when there is nothing to do); returning `nil` is a defect.

If a finalizer fails: when the effect had succeeded, the whole effect fails with the finalizer's cause; when the effect had failed, the cause becomes `Sequential(original, finalizer cause)`, which the expected-error handlers do not catch (it contains a defect or a second failure).

### eff:ensuring(finalizer)

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

### eff:onExit(fin)

```lua
eff:onExit(fin: fun(exit: Exit<A>): Effect<any, any>) -> Effect<A, E>
```

- **Parameters:** `fin`, called with the [Exit](core-errors.md#fxexit) of `eff`; must return an effect.
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

### eff:onError(f)

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

### eff:onInterrupt(f)

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

### Fx.acquireUseRelease(acquire, use, release)

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

## Scope

A scope collects finalizers and runs them, last added first, when it closes. `Fx.Scope` is both the scope module and the [service tag](#services) of the current scope: `Fx.yield(Fx.Scope)` returns the scope your code runs in. Every open scope also closes when the resource stops.

### Fx.scoped(eff)

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

### Fx.acquireRelease(acquire, release)

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

### Fx.addFinalizer(fin)

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

### Fx.Scope.make() and Fx.Scope.unsafeMake()

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

### scope:addFinalizer(fin)

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

### scope:close(exit?)

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

### scope:closeSync(exit?)

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

### scope:fork()

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

### scope:extend(eff)

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

### scope:unsafeAttachFiber(fiber)

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

`eff:forkScoped()` is documented on the [Concurrency](core-concurrency.md#effforkscoped) page.

## Resource lifecycle

When this resource stops (`onResourceStop` for its own name), Rivo FX:

1. interrupts every root fiber (`Fx.runFork`, `runAwait`, `forkDaemon`, `forkScoped` fibers; children follow their parents), with fiber id `0` in the cause;
2. closes every open scope synchronously with `closeSync`, newest first, with an interruption exit. This includes `Fx.resourceScope`, player scopes and Runtime scopes.

There is no later tick after a resource stops, so finalizers that need to wait are reported and skipped. Keep stop-time cleanup synchronous (`DeleteEntity`, `SetModelAsNoLongerNeeded`, state resets).

### Fx.onStop(fin)

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

### Fx.resourceScope

```lua
Fx.resourceScope: ScopeObject
```

- **Notes:** a scope that closes when this resource stops. Use `Fx.resourceScope:extend(eff)` for resources that live as long as the resource. For per-player lifetimes see `Fx.player.scope(src)` in [FiveM modules](fivem-modules.md).

```lua
local loadModel = Fx.acquireRelease(Fx.succeed('prop_atm_01'), function(m)
  return Fx.sync(function() print('SetModelAsNoLongerNeeded', m) end)
end)
Fx.runSync(Fx.resourceScope:extend(loadModel))
Fx.resourceScope:closeSync()
--> SetModelAsNoLongerNeeded prop_atm_01
```

## Services

A service is any value (usually a table of functions returning effects) looked up by a tag. Code asks for the service by yielding its tag; whoever runs the code provides it.

### Fx.Tag(key)

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

### Fx.isTag(value)

```lua
Fx.isTag(value: any) -> boolean
```

```lua
print(Fx.isTag(Fx.Tag('Garage')), Fx.isTag(Fx.unit)) --> true false
```

### Fx.serviceOption(tag)

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

### eff:provideService(tag, service)

```lua
eff:provideService(tag: Tag, service: any) -> Effect<A, E>
```

- **Returns:** `eff` with `service` available under `tag`. Inner provides win over outer ones.

```lua
local Config = Fx.Tag('Config')
local eff = Config:map(function(c) return c.maxVehicles end):provideService(Config, { maxVehicles = 3 })
print(Fx.runSync(eff)) --> 3
```

### eff:provideContext(ctx)

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

## Layer

A layer is a recipe that builds services, possibly using other services and acquiring resources. Within one build, each layer object is built at most once even if it appears several times in the graph. Separate builds (two `eff:provide(layer)` calls, two runtimes) build it again.

### Fx.Layer.succeed(tag, service)

```lua
Fx.Layer.succeed(tag: Tag, service: any) -> Layer
```

- **Returns:** a layer that provides `service` as is.

```lua
local Bank = Fx.Tag('Bank')
local BankLive = Fx.Layer.succeed(Bank, { name = 'Fleeca' })
print(Fx.runSync(Bank:provide(BankLive)).name) --> Fleeca
```

### Fx.Layer.sync(tag, fn)

```lua
Fx.Layer.sync(tag: Tag, fn: fun(): any) -> Layer
```

- **Returns:** a layer that calls `fn` when it builds and provides the result.

```lua
local Shops = Fx.Tag('Shops')
local ShopsLive = Fx.Layer.sync(Shops, function() return { count = 12 } end)
print(Fx.runSync(Shops:provide(ShopsLive)).count) --> 12
```

### Fx.Layer.effect(tag, eff)

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

### Fx.Layer.scoped(tag, eff)

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

### Fx.Layer.effectDiscard(eff)

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

### Fx.Layer.empty

```lua
Fx.Layer.empty: Layer
```

- **Notes:** provides nothing. Useful as a starting value when building layer lists.

```lua
print(Fx.runSync(Fx.succeed(1):provide(Fx.Layer.empty))) --> 1
```

### Fx.Layer.merge(...)

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

### layer:provide(dep)

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

### layer:provideMerge(dep)

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

### layer:build(scope)

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

### eff:provide(layerOrContext)

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

## Runtime

A runtime builds a layer once and shares its services with every effect it runs. Make one per resource for your services and register it with [Fx.setRuntime](core-effects.md#fxsetruntimert) so `Fx.net` and `Fx.rpc` handlers get them.

### Fx.Runtime.make(layer)

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

### rt:runFork(eff, opts?)

```lua
rt:runFork(eff: Effect<A, E>, opts?: { onExit?: fun(exit: Exit<A>) }) -> Fiber
```

- **Returns:** a root fiber running `eff` with the runtime's services, as [Fx.runFork](core-effects.md#fxrunforkeff-opts).

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, { name = 'Pacific Standard' }))
rt:runFork(Bank, { onExit = function(exit) print(exit.value.name) end }) --> Pacific Standard
```

### rt:runCallback(eff, cb)

```lua
rt:runCallback(eff: Effect<A, E>, cb: fun(exit: Exit<A>)) -> Fiber
```

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, 'fleeca'))
rt:runCallback(Bank, function(exit) print(exit._tag, exit.value) end) --> Success fleeca
```

### rt:runAwait(eff)

```lua
rt:runAwait(eff: Effect<A, E>) -> A
```

- **Returns:** the value, blocking the calling Citizen thread. Raises like [Fx.runAwait](core-effects.md#fxrunawaiteff-opts).

```lua
local Bank = Fx.Tag('Bank')
local rt = Fx.Runtime.make(Fx.Layer.succeed(Bank, { balance = function(src) return Fx.succeed(src * 100) end }))
CreateThread(function()
  local bal = rt:runAwait(Fx.gen(function() return Fx.yield(Fx.yield(Bank).balance(3)) end))
  print('balance', bal)
end)
--> balance 300
```

### rt:context() and rt:wrap(eff)

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

### rt:dispose()

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
