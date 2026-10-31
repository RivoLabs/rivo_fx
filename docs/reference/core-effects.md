# Core effects

This page covers building effects, chaining them, writing them in direct style with `Fx.gen`, working with time, and running them. An effect (`Effect<A, E>`) is an immutable description of a program that succeeds with a value of type `A` or fails with an error of type `E`. Nothing runs until a fiber interprets it, so the same effect can run many times. Read this page first; [Errors](core-errors.md), [Concurrency](core-concurrency.md), [Resources](core-resources.md), [Schedule](core-schedule.md) and [Schema](core-schema.md) build on it.

Examples print values with a `--> result` comment showing what they print.

## How fibers run

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

## Building effects

### Fx.succeed(value)

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

### Fx.fail(err)

```lua
Fx.fail(err: E) -> Effect<never, E>
```

- **Parameters:** `err`, the expected error. Usually a tagged error (see [Errors](core-errors.md)), but any value works.
- **Returns:** an effect that fails with `err`.
- **Fails with:** `err`.
- **Notes:** a tagged error instance has a shortcut: `NotEnoughMoney { need = 50 }:fail()` is the same as `Fx.fail(NotEnoughMoney { need = 50 })`.

```lua
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')
local eff = Fx.fail(NotEnoughMoney { need = 50 })
local exit = Fx.runSyncExit(eff)
print(Fx.Cause.failureOption(exit.cause)._tag) --> NotEnoughMoney
```

### Fx.die(defect)

```lua
Fx.die(defect: any) -> Effect<never, never>
```

- **Parameters:** `defect`, any value describing a bug.
- **Returns:** an effect that fails with a defect (an unexpected error). A Lua traceback of the call site is kept in the cause.
- **Fails with:** a defect, which `catchAll`, `catchTag` and the other expected-error handlers do not catch. See [Errors](core-errors.md#failures-defects-and-interruptions).

```lua
local exit = Fx.runSyncExit(Fx.die('vehicle table corrupted'))
print(Fx.Cause.defects(exit.cause)[1]) --> vehicle table corrupted
```

### Fx.failCause(cause)

```lua
Fx.failCause(cause: Cause) -> Effect<never, any>
```

- **Parameters:** `cause`, a [Cause](core-errors.md#fxcause).
- **Returns:** an effect that fails with exactly that cause.
- **Fails with:** whatever the cause holds.
- **Notes:** used to re-raise a cause you inspected in `catchAllCause` or `onExit`.

```lua
local eff = Fx.failCause(Fx.Cause.fail('busy'))
print(Fx.Cause.failureOption(Fx.runSyncExit(eff).cause)) --> busy
```

### Fx.sync(fn)

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

### Fx.try(fn, onError?)

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

### Fx.suspend(fn)

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

### Fx.async(register)

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

### Fx.callback(register)

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

### Fx.fromPromise(p)

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

### Fx.fromNullable(value, onNil?)

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

### Fx.fromExit(exit)

```lua
Fx.fromExit(exit: Exit<A>) -> Effect<A, any>
```

- **Parameters:** `exit`, an [Exit](core-errors.md#fxexit).
- **Returns:** an effect that succeeds with `exit.value` or fails with `exit.cause`.

```lua
print(Fx.runSync(Fx.fromExit(Fx.Exit.succeed('ok')))) --> ok
```

### Fx.withFiber(f)

```lua
Fx.withFiber(f: fun(fiber: Fiber): Effect<A, E>) -> Effect<A, E>
```

- **Parameters:** `f`, called with the running [fiber](core-concurrency.md#fibers); must return an effect.
- **Returns:** the effect `f` returns.
- **Notes:** low level. `Fx.fiberId` covers the common case.

```lua
local eff = Fx.withFiber(function(fiber) return Fx.succeed(type(fiber.id)) end)
print(Fx.runSync(eff)) --> number
```

### Fx.unit and Fx.void

```lua
Fx.unit: Effect<nil, never>
Fx.void: Effect<nil, never>
```

- **Returns:** an effect that succeeds with `nil`. `Fx.void` is the same value as `Fx.unit`.
- **Notes:** finalizers, `onExit` callbacks and handlers that must return an effect often return `Fx.unit`.

```lua
print(Fx.runSync(Fx.unit)) --> nil
```

### Fx.never

```lua
Fx.never: Effect<never, never>
```

- **Returns:** an effect that never finishes.
- **Notes:** it parks the fiber forever at no cost. The fiber stops only when interrupted (its parent ends, a timeout, a closed scope, resource stop). Useful to keep a scope open until the resource stops.

```lua
Fx.runFork(Fx.never:timeoutOption(100), { onExit = function(exit) print(exit.value) end }) --> nil
```

### Fx.yieldNow

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

### Fx.fiberId

```lua
Fx.fiberId: Effect<integer, never>
```

- **Returns:** an effect that succeeds with the id of the fiber running it.
- **Notes:** fiber ids are unique per resource and increase. Effects run by `timeout`, `race`, `forEach` with concurrency and `fork` run on other fibers and see other ids.

```lua
Fx.runFork(Fx.fiberId, { onExit = function(exit) print(math.type(exit.value)) end }) --> integer
```

### Fx.isEffect(value)

```lua
Fx.isEffect(value: any) -> boolean
```

- **Returns:** `true` when `value` is an effect (including service tags).

```lua
print(Fx.isEffect(Fx.unit), Fx.isEffect(function() end)) --> true false
```

## Chaining

### eff:map(f)

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

### eff:flatMap(f)

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

### eff:andThen(next)

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

### eff:tap(f)

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

### eff:as(value)

```lua
eff:as(value: B) -> Effect<B, E>
```

- **Returns:** an effect that runs `eff` and succeeds with `value` instead.

```lua
print(Fx.runSync(Fx.sync(function() end):as('paid'))) --> paid
```

### eff:asVoid()

```lua
eff:asVoid() -> Effect<nil, E>
```

- **Returns:** an effect that runs `eff` and succeeds with `nil`.

```lua
print(Fx.runSync(Fx.succeed(5):asVoid())) --> nil
```

### eff:zip(that)

```lua
eff:zip(that: Effect<B, E2>) -> Effect<{ [1]: A, [2]: B }, E | E2>
```

- **Returns:** an effect that runs `eff`, then `that`, and succeeds with `{ a, b }`.
- **Notes:** sequential. For concurrent runs use [Fx.all](core-concurrency.md#fxalleffects-opts).

```lua
local pair = Fx.runSync(Fx.succeed('Ana'):zip(Fx.succeed(1500)))
print(pair[1], pair[2]) --> Ana 1500
```

### eff:zipLeft(that)

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

### eff:zipRight(that)

```lua
eff:zipRight(that: Effect<B, E2>) -> Effect<B, E | E2>
```

- **Returns:** an effect that runs `eff`, then `that`, and keeps the value of `that`.

```lua
print(Fx.runSync(Fx.sync(function() end):zipRight(Fx.succeed('next')))) --> next
```

### eff:filterOrFail(pred, onFalse)

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

### eff:forever()

```lua
eff:forever() -> Effect<never, E>
```

- **Returns:** an effect that runs `eff` again after every success, forever.
- **Fails with:** the first failure of `eff`, which stops the loop.
- **Notes:** add a wait (`:delay(ms)`) or the loop only gives the frame back every 2048 steps. For a counted or timed loop use [repeatWith](core-schedule.md#effrepeatwithschedule).

```lua
local ticks = 0
local loop = Fx.sync(function() ticks = ticks + 1 end):delay(1000):forever()
Fx.runFork(loop:timeoutOption(3500), { onExit = function() print(ticks) end }) --> 3
```

Error handling (`catchAll`, `catchTag`, `mapError`, `result`, `match` and the rest) is on the [Errors](core-errors.md) page. Finalizers (`ensuring`, `onExit`, `onError`, `onInterrupt`) are on the [Resources](core-resources.md) page.

## Direct style with Fx.gen

### Fx.gen(body, ...)

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

### Fx.yield(eff)

```lua
Fx.yield(eff: Effect<A, E>) -> A
```

- **Parameters:** `eff`, the effect to run.
- **Returns:** the success value of `eff`, inside an `Fx.gen` body.
- **Fails with:** on failure the `Fx.gen` stops at this point and fails with the same cause.
- **Notes:** outside `Fx.gen` it raises `Fx.yield called outside Fx.gen ...`. Yielding something that is not an effect makes the gen die with `Fx.yield expects an effect, got <type>`. Yield a [service tag](core-resources.md#fxtagkey) to get the service.

```lua
local eff = Fx.gen(function()
  local a = Fx.yield(Fx.succeed(2))
  local b = Fx.yield(Fx.succeed(3):delay(100))
  return a * b
end)
Fx.runFork(eff, { onExit = function(exit) print(exit.value) end }) --> 6
```

### eff:await()

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

## Time

Delays are in milliseconds and use the game timer (`GetGameTimer`).

### Fx.sleep(ms)

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

### eff:delay(ms)

```lua
eff:delay(ms: integer) -> Effect<A, E>
```

- **Returns:** an effect that waits `ms`, then runs `eff`.

```lua
Fx.runFork(Fx.succeed('engine on'):delay(1500), { onExit = function(exit) print(exit.value) end }) --> engine on
```

### eff:timeout(ms)

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

### eff:timeoutFail(ms, onTimeout)

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

### eff:timeoutOption(ms)

```lua
eff:timeoutOption(ms: integer) -> Effect<A | nil, E>
```

- **Returns:** an effect that succeeds with the value of `eff`, or with `nil` when the time runs out.
- **Notes:** a `TimeoutError` raised by `eff` itself also becomes `nil`, because it is caught by tag.

```lua
local waitForPlayer = Fx.sleep(10000):as(3)
Fx.runFork(waitForPlayer:timeoutOption(2000), { onExit = function(exit) print(exit.value) end }) --> nil
```

### eff:retry(policy)

```lua
eff:retry(policy: integer | Schedule | RetryPolicy) -> Effect<A, E>
```

- **Parameters:** `policy`, a number of retries, a [Schedule](core-schedule.md), or a table `{ times?, schedule?, while?, until? }`.
- **Returns:** an effect that runs `eff` again after each expected failure, as the policy allows.
- **Fails with:** the last error when the policy stops. Defects and interruptions are not retried.
- **Notes:** full details on the [Schedule](core-schedule.md#effretrypolicy) page.

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

### eff:repeatWith(schedule)

```lua
eff:repeatWith(schedule: Schedule | integer) -> Effect<A, E>
```

- **Returns:** an effect that runs `eff`, then runs it again after each success as the schedule allows, and succeeds with the last value.
- **Fails with:** the first failure, which stops the repeat.
- **Notes:** `eff['repeat'](eff, schedule)` is the same function (`repeat` is a Lua keyword). `eff:repeatN(n)` runs `eff` `n + 1` times. Details on the [Schedule](core-schedule.md#effrepeatwithschedule) page.

```lua
local saves = 0
local autosave = Fx.sync(function() saves = saves + 1 end):repeatWith(Fx.Schedule.spaced(60000):take(2))
Fx.runFork(autosave, { onExit = function() print(saves) end }) --> 3
```

### Fx.poll(check, timeout, onTimeout)

```lua
Fx.poll(check: fun(): boolean, timeout: integer, onTimeout: fun(): E) -> Effect<nil, E>
```

- **Parameters:** `check`, called once per tick until it returns true. `timeout`, the time limit in ms. `onTimeout`, builds the error.
- **Returns:** an effect that succeeds with `nil` once `check()` is true.
- **Fails with:** `onTimeout()` after `timeout` ms.
- **Notes:** `Fx.poll` is defined by the assets module, so it is `nil` until `Fx.assets` has been accessed once in the resource. Touch `Fx.assets` first (`local _ = Fx.assets`). For loading game assets use [Fx.assets](fivem-modules.md) directly.

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

## Running effects

Every `run*` function accepts an optional `opts.context` table (tag to service) that becomes the fiber's initial services. Most code uses [Runtime](core-resources.md#runtime) or `eff:provide(layer)` instead.

### Fx.runFork(eff, opts?)

```lua
Fx.runFork(eff: Effect<A, E>, opts?: { onExit?: fun(exit: Exit<A>), context?: table }) -> Fiber
```

- **Parameters:** `eff`, the effect. `opts.onExit`, called with the [Exit](core-errors.md#fxexit) when the fiber ends. `opts.context`, initial services.
- **Returns:** the new root [fiber](core-concurrency.md#fibers), right away. It starts on the next tick.
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

### Fx.runCallback(eff, cb, opts?)

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

### Fx.runAwait(eff, opts?)

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

### Fx.runSync(eff, opts?)

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

### Fx.runSyncExit(eff, opts?)

```lua
Fx.runSyncExit(eff: Effect<A, E>, opts?: { context?: table }) -> Exit<A>
```

- **Returns:** the [Exit](core-errors.md#fxexit) of running `eff` synchronously. Never raises for effect failures.

```lua
local exit = Fx.runSyncExit(Fx.fail('no license'))
print(exit._tag, Fx.Cause.failureOption(exit.cause)) --> Failure no license
```

### Fx.setRuntime(rt)

```lua
Fx.setRuntime(rt: Runtime) -> nil
```

- **Parameters:** `rt`, a [Runtime](core-resources.md#runtime).
- **Notes:** makes `rt` the default runtime for `Fx.net` handlers, `Fx.rpc` handlers and the `Fx.compat` ox_lib bridge in this resource, so their handlers can yield the runtime's services. It does not affect `Fx.runFork`, `Fx.runAwait` or `Fx.runSync`; use `rt:runFork(eff)` for those. A per-handler `runtime` option overrides it (see [Net and RPC](net-rpc.md)).

```lua
local Bank = Fx.Tag('Bank')
Fx.setRuntime(Fx.Runtime.make(Fx.Layer.succeed(Bank, { name = 'Maze Bank' })))
-- Fx.rpc.register(...) handlers can now Fx.yield(Bank).
```

### Fx.setPlatform(p) and Fx.getPlatform()

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
