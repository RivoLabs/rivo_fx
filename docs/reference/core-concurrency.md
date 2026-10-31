# Core concurrency

This page covers fibers (fork, join, interrupt), running many effects at once with `Fx.forEach`, `Fx.all` and races, uninterruptible regions, and the shared-state tools: `Ref`, `Deferred`, `Semaphore`, `Queue` and `PubSub`. Use it when work has to run in the background, in parallel, or has to coordinate between fibers. Fibers are cooperative coroutines in one Lua state; "concurrent" means interleaved while fibers wait, never two pieces of Lua running at the same instant. See [How fibers run](core-effects.md#how-fibers-run).

Examples print values with a `--> result` comment showing what they print.

## Fibers

A fiber runs one effect. It has a numeric `id` and, once finished, an `exit` field holding its [Exit](core-errors.md#fxexit) (`nil` while running). Fibers start on the next pass of the runner, not at the moment you fork them.

How fibers are tied together:

| Started with | Parent | Interrupted when | Unhandled failure logged |
|---|---|---|---|
| `eff:fork()` | the forking fiber | the parent finishes (for any reason), or resource stop through the parent | no; join it or handle errors inside it |
| `eff:forkDaemon()` | none (root fiber) | resource stop, or you interrupt it | yes |
| `eff:forkScoped()` | none (root fiber) | the current `Scope` closes, or resource stop | yes |
| `Fx.runFork(eff)` | none (root fiber) | resource stop, or you interrupt it | yes, unless `onExit` is given |

### eff:fork()

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

### eff:forkDaemon()

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

### eff:forkScoped()

```lua
eff:forkScoped() -> Effect<Fiber, never>  -- requires Scope
```

- **Returns:** an effect that starts `eff` as a daemon fiber and interrupts it when the current [Scope](core-resources.md#scope) closes.
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

### fiber:join()

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

### fiber:await()

```lua
fiber:await() -> Effect<Exit<A>, never>
```

- **Returns:** an effect that waits for the fiber and succeeds with its [Exit](core-errors.md#fxexit). It never fails.

```lua
local eff = Fx.gen(function()
  local f = Fx.yield(Fx.fail('no fuel'):fork())
  local exit = Fx.yield(f:await())
  return exit._tag
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> Failure
```

### fiber:interrupt()

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

### fiber:interruptAsFork(byId?)

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

### fiber:addObserver(cb)

```lua
fiber:addObserver(cb: fun(exit: Exit<A>)) -> fun()
```

- **Returns:** a function that removes the observer.
- **Notes:** plain Lua callback, called once when the fiber ends. Errors raised in `cb` at that point are reported, not raised. If the fiber has already ended, `cb` is called right away and its errors propagate to the caller.

```lua
local f = Fx.runFork(Fx.succeed(7):delay(50), { onExit = function() end })
f:addObserver(function(exit) print('done with', exit.value) end) --> done with 7
```

### Fx.interruptAll(fibers)

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

## Running many effects

### Fx.forEach(items, f, opts?)

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

### Fx.all(effects, opts?)

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

### eff:race(that)

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

### eff:raceFirst(that)

```lua
eff:raceFirst(that: Effect<A, E>) -> Effect<A, E>
```

- **Returns:** an effect whose result is that of whichever side **finishes** first, success or failure. The other side is interrupted.

```lua
local eff = Fx.fail('player dropped'):delay(10):raceFirst(Fx.succeed('trade done'):delay(50))
Fx.runFork(eff, { onExit = function(exit) print(Fx.Cause.failureOption(exit.cause)) end }) --> player dropped
```

### Fx.raceAll(effects)

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

## Interruption

Interruption is how fibers are stopped: `fiber:interrupt()`, a timeout, a race loser, a parent finishing, a scope closing, resource stop. An interrupted fiber stops at its next step (at once if it is waiting on `Fx.sleep`, `Fx.async`, a `Queue` or a `Deferred`), runs its finalizers, and ends with an `Interrupt` cause. Recovery handlers do not run during interruption (see [Errors](core-errors.md#failures-defects-and-interruptions)).

### eff:uninterruptible()

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

### eff:interruptible()

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

### Fx.uninterruptibleMask(f)

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

## Ref

A mutable cell shared by fibers. Every operation is an effect and runs without interleaving, so `update` and `modify` are atomic with respect to other fibers.

### Fx.Ref.make(value) and Fx.Ref.unsafeMake(value)

```lua
Fx.Ref.make(value: A) -> Effect<Ref<A>, never>
Fx.Ref.unsafeMake(value: A) -> Ref<A>
```

- **Returns:** a new ref. `unsafeMake` builds it immediately, outside any effect (for module-level state).

```lua
local onlineCount = Fx.Ref.unsafeMake(0)
print(Fx.runSync(onlineCount:get())) --> 0
```

### ref:get(), ref:set(value)

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

### ref:update(f), ref:updateAndGet(f), ref:getAndSet(value)

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

### ref:modify(f)

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

## Deferred

A value set once and awaited by any number of fibers.

### Fx.Deferred.make() and Fx.Deferred.unsafeMake()

```lua
Fx.Deferred.make() -> Effect<Deferred<A, E>, never>
Fx.Deferred.unsafeMake() -> Deferred<A, E>
```

```lua
local d = Fx.Deferred.unsafeMake()
print(d:isDone()) --> false
```

### deferred:await()

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

### deferred:succeed(value), deferred:fail(err), deferred:done(exit)

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

### deferred:isDone()

```lua
deferred:isDone() -> boolean
```

- **Notes:** plain function, not an effect.

```lua
local d = Fx.Deferred.unsafeMake()
d:unsafeDone(Fx.Exit.succeed(1))
print(d:isDone()) --> true
```

## Semaphore

Limits how many fibers run a section at once. Waiters are served in order (FIFO): a request waits while anyone is queued ahead of it, even if enough permits are free.

### Fx.Semaphore.make(permits) and Fx.Semaphore.unsafeMake(permits)

```lua
Fx.Semaphore.make(permits: integer) -> Effect<Semaphore, never>
Fx.Semaphore.unsafeMake(permits: integer) -> Semaphore
```

```lua
local garageSlots = Fx.Semaphore.unsafeMake(2)
print(garageSlots.permits) --> 2
```

### semaphore:withPermit(eff) and semaphore:withPermits(n, eff)

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

### semaphore:take(n?) and semaphore:release(n?)

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

## Queue

A FIFO between fibers. `take` waits while the queue is empty. What `offer` does on a full queue depends on the strategy:

| Constructor | Capacity | `offer` when full |
|---|---|---|
| `Fx.Queue.unbounded()` | unlimited | never full |
| `Fx.Queue.bounded(n)` | `n` | waits for room (strategy `'suspend'`) |
| `Fx.Queue.dropping(n)` | `n` | drops the new item, succeeds with `false` |
| `Fx.Queue.sliding(n)` | `n` | drops the oldest item, adds the new one, succeeds with `true` |

### Fx.Queue.unbounded(), bounded(n), dropping(n), sliding(n)

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

### Fx.Queue.unsafeMake(capacity?, strategy?) and Fx.Queue.unsafeUnbounded()

```lua
Fx.Queue.unsafeMake(capacity?: integer, strategy?: 'suspend' | 'dropping' | 'sliding') -> Queue
Fx.Queue.unsafeUnbounded() -> Queue
```

- **Notes:** build a queue immediately, outside any effect. Defaults: unbounded, `'suspend'`.

```lua
local jobs = Fx.Queue.unsafeMake(10, 'dropping')
print(jobs.capacity, jobs.strategy) --> 10 dropping
```

### queue:offer(value)

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

### queue:take()

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

### queue:poll(), queue:takeAll(), queue:size()

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

### queue:unsafeOffer(value), queue:unsafePoll(), queue:unsafeSize()

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

## PubSub

Broadcasts each message to every subscriber that subscribed before it was published.

### Fx.PubSub.make() and Fx.PubSub.unsafeMake()

```lua
Fx.PubSub.make() -> Effect<PubSub, never>
Fx.PubSub.unsafeMake() -> PubSub
```

```lua
local weatherChanged = Fx.PubSub.unsafeMake()
print(type(weatherChanged.subscribe)) --> function
```

### pubsub:publish(value) and pubsub:unsafePublish(value)

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

### pubsub:subscribe(opts?)

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

### pubsub:on(fn)

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

For a stream of published values (`Fx.Stream.fromPubSub`), see [Streams](streams.md).
