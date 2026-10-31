# Core errors

This page covers typed errors (`Fx.TaggedError`), the operators that recover from or transform errors, the difference between failures, defects and interruptions, and the `Fx.Cause` and `Fx.Exit` values that describe how an effect ended. Use tagged errors for every failure a caller may want to handle, and let bugs stay defects. The catalogue of tags raised by the FiveM modules is on the [Errors catalogue](errors.md) page.

Examples print values with a `--> result` comment showing what they print.

## Failures, defects and interruptions

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

## Tagged errors

### Fx.TaggedError(tag, fields?)

```lua
Fx.TaggedError(tag: string, fields?: table<string, Schema>) -> TaggedErrorClass
```

- **Parameters:** `tag`, the name stored in `_tag`. `fields`, optional table of [schemas](core-schema.md) checked every time an instance is built.
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

### err:fail()

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

### error(TaggedError) inside effect code

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

## Recovering from errors

All of these take a handler that **must return an effect**. Returning a plain value from the handler is a defect (`expected an Fx effect but got ...`), except where noted.

### eff:catchAll(f)

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

### eff:catchTag(tag, f)

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

### eff:catchTags(handlers)

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

### eff:catchIf(pred, f)

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

### eff:catchAllCause(f)

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

### eff:catchAllDefect(f)

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

### eff:mapError(f)

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

### eff:tapError(f)

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

### eff:tapErrorCause(f)

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

### eff:orElse(f)

```lua
eff:orElse(f: fun(): Effect<B, E2>) -> Effect<A | B, E2>
```

- **Returns:** the effect `f()` returns when `eff` fails with an expected error. `f` gets no arguments.

```lua
local primary = Fx.fail('primary garage full')
local backup = function() return Fx.succeed('parked at backup garage') end
print(Fx.runSync(primary:orElse(backup))) --> parked at backup garage
```

### eff:orElseSucceed(value)

```lua
eff:orElseSucceed(value: B) -> Effect<A | B, never>
```

- **Returns:** an effect that succeeds with `value` when `eff` fails with an expected error.

```lua
print(Fx.runSync(Fx.fail('no job'):orElseSucceed('unemployed'))) --> unemployed
```

### eff:orDie()

```lua
eff:orDie() -> Effect<A, never>
```

- **Returns:** an effect whose expected errors become defects (the error value is the defect).
- **Notes:** use it when a failure here can only mean a bug, for example config that was already validated.

```lua
local exit = Fx.runSyncExit(Fx.fail('config missing'):orDie())
print(#Fx.Cause.failures(exit.cause), Fx.Cause.defects(exit.cause)[1]) --> 0 config missing
```

### eff:result()

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

### eff:option()

```lua
eff:option() -> Effect<A | nil, never>
```

- **Returns:** an effect that succeeds with the value, or `nil` on an expected failure.

```lua
print(Fx.runSync(Fx.fail('no vehicle'):option())) --> nil
```

### eff:exit()

```lua
eff:exit() -> Effect<Exit<A>, never>
```

- **Returns:** an effect that succeeds with the [Exit](#fxexit) of `eff`, for any outcome including defects.
- **Notes:** an interruption of the fiber running it still propagates.

```lua
local exit = Fx.runSync(Fx.die('oops'):exit())
print(exit._tag) --> Failure
```

### eff:match(handlers)

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

### eff:matchEffect(handlers)

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

### eff:foldCauseEffect(onFailure, onSuccess)

```lua
eff:foldCauseEffect(onFailure: fun(cause: Cause): Effect<B, E2>, onSuccess?: fun(a: A): Effect<B, E2>) -> Effect<B, E2>
```

- **Parameters:** `onFailure` gets the full cause. `onSuccess` may be `nil` to keep the value.
- **Notes:** the primitive the other handlers are built on. Skipped while the fiber itself is being interrupted.

```lua
local eff = Fx.fail('x'):foldCauseEffect(function(c) return Fx.succeed('cause had ' .. #Fx.Cause.failures(c) .. ' failure') end)
print(Fx.runSync(eff)) --> cause had 1 failure
```

Finalizers that observe errors without recovering (`onError`, `onExit`, `ensuring`, `onInterrupt`) are on the [Resources](core-resources.md) page.

## Fx.Cause

A cause is a plain table with a `_tag`:

| `_tag` | Fields |
|---|---|
| `'Empty'` | none |
| `'Fail'` | `error` |
| `'Die'` | `defect`, `trace` (string or nil) |
| `'Interrupt'` | `fiberId` (the interrupting fiber's id; `0` for resource stop and scope closing) |
| `'Sequential'` | `left`, `right` (one thing happened, then another, for example a failure and then a failing finalizer) |
| `'Parallel'` | `left`, `right` (concurrent failures, for example both sides of a `race`) |

### Fx.Cause.fail(err)

```lua
Fx.Cause.fail(err: any) -> Cause
```

- **Returns:** `{ _tag = 'Fail', error = err }`.

```lua
print(Fx.Cause.fail('x')._tag) --> Fail
```

### Fx.Cause.die(defect, trace?)

```lua
Fx.Cause.die(defect: any, trace?: string) -> Cause
```

- **Returns:** `{ _tag = 'Die', defect = defect, trace = trace }`.

```lua
print(Fx.Cause.die('bug').defect) --> bug
```

### Fx.Cause.interrupt(fiberId?)

```lua
Fx.Cause.interrupt(fiberId?: integer) -> Cause
```

- **Returns:** `{ _tag = 'Interrupt', fiberId = fiberId }`.

```lua
print(Fx.Cause.isInterrupted(Fx.Cause.interrupt(7))) --> true
```

### Fx.Cause.sequential(left, right) and Fx.Cause.parallel(left, right)

```lua
Fx.Cause.sequential(left: Cause, right: Cause) -> Cause
Fx.Cause.parallel(left: Cause, right: Cause) -> Cause
```

- **Returns:** the combined cause. If one side is `Fx.Cause.empty`, the other side is returned as is.

```lua
local c = Fx.Cause.sequential(Fx.Cause.fail('a'), Fx.Cause.die('b'))
print(c._tag, #Fx.Cause.failures(c), #Fx.Cause.defects(c)) --> Sequential 1 1
```

### Fx.Cause.empty

```lua
Fx.Cause.empty: Cause -- { _tag = 'Empty' }
```

```lua
print(Fx.Cause.parallel(Fx.Cause.empty, Fx.Cause.fail('x'))._tag) --> Fail
```

### Fx.Cause.failures(cause)

```lua
Fx.Cause.failures(cause: Cause) -> any[]
```

- **Returns:** every expected error in the cause, left to right.

```lua
local c = Fx.Cause.parallel(Fx.Cause.fail('a'), Fx.Cause.fail('b'))
print(table.concat(Fx.Cause.failures(c), ',')) --> a,b
```

### Fx.Cause.failureOption(cause)

```lua
Fx.Cause.failureOption(cause: Cause) -> any | nil
```

- **Returns:** the first expected error, or `nil`.

```lua
print(Fx.Cause.failureOption(Fx.Cause.die('x'))) --> nil
```

### Fx.Cause.defects(cause)

```lua
Fx.Cause.defects(cause: Cause) -> any[]
```

- **Returns:** every defect value, left to right.

```lua
print(#Fx.Cause.defects(Fx.Cause.die('x'))) --> 1
```

### Fx.Cause.isInterrupted(cause)

```lua
Fx.Cause.isInterrupted(cause: Cause) -> boolean
```

- **Returns:** `true` when the cause holds at least one interruption.

```lua
print(Fx.Cause.isInterrupted(Fx.Cause.fail('x'))) --> false
```

### Fx.Cause.isInterruptedOnly(cause)

```lua
Fx.Cause.isInterruptedOnly(cause: Cause) -> boolean
```

- **Returns:** `true` when the cause holds interruptions and nothing else. Unhandled-failure logging skips these.

```lua
local c = Fx.Cause.sequential(Fx.Cause.interrupt(1), Fx.Cause.die('finalizer crashed'))
print(Fx.Cause.isInterrupted(c), Fx.Cause.isInterruptedOnly(c)) --> true false
```

### Fx.Cause.squash(cause)

```lua
Fx.Cause.squash(cause: Cause) -> any
```

- **Returns:** the first failure; else the first defect; else the string `'interrupted'`; else `'empty cause'`.

```lua
print(Fx.Cause.squash(Fx.Cause.interrupt(3))) --> interrupted
```

### Fx.Cause.pretty(cause)

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

### Fx.Cause.describe(value)

```lua
Fx.Cause.describe(value: any) -> string
```

- **Returns:** the rendering `pretty` uses for one error or defect.

```lua
print(Fx.Cause.describe({ _tag = 'Busy', retryIn = 5 })) --> Busy { retryIn = 5 }
```

### Fx.Cause.walk(cause, fn)

```lua
Fx.Cause.walk(cause: Cause, fn: fun(node: Cause)) -> nil
```

- **Notes:** calls `fn` for every `Fail`, `Die` and `Interrupt` node, left to right.

```lua
local tags = {}
Fx.Cause.walk(Fx.Cause.parallel(Fx.Cause.fail('a'), Fx.Cause.interrupt(1)), function(n) tags[#tags + 1] = n._tag end)
print(table.concat(tags, ' ')) --> Fail Interrupt
```

## Fx.Exit

An exit is how a fiber ended: `{ _tag = 'Success', value = v }` or `{ _tag = 'Failure', cause = c }`. You get one from `Fx.runFork` / `Fx.runCallback` `onExit`, `Fx.runSyncExit`, `fiber:await()`, `eff:exit()`, `onExit` finalizers and scope finalizers.

### Fx.Exit.succeed(value)

```lua
Fx.Exit.succeed(value: A) -> Exit<A>
```

```lua
print(Fx.Exit.succeed(5).value) --> 5
```

### Fx.Exit.failCause(cause)

```lua
Fx.Exit.failCause(cause: Cause) -> Exit<never>
```

```lua
print(Fx.Exit.failCause(Fx.Cause.fail('x'))._tag) --> Failure
```

### Fx.Exit.isSuccess(exit) and Fx.Exit.isFailure(exit)

```lua
Fx.Exit.isSuccess(exit: Exit) -> boolean
Fx.Exit.isFailure(exit: Exit) -> boolean
```

```lua
local exit = Fx.runSyncExit(Fx.succeed(1))
print(Fx.Exit.isSuccess(exit), Fx.Exit.isFailure(exit)) --> true false
```

### Fx.Exit.unit

```lua
Fx.Exit.unit: Exit<nil> -- { _tag = 'Success', value = nil }
```

- **Notes:** the exit passed to scope finalizers when a scope is closed without one.

```lua
print(Fx.Exit.unit._tag) --> Success
```

## Errors across boundaries

### Fx.serializeError(err)

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

### Fx.taggedFromTable(t)

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

### Fx.inspect(value)

```lua
Fx.inspect(value: any) -> string
```

- **Returns:** a one-line rendering for logs. Strings are quoted, table keys are sorted, nesting deeper than 3 levels shows `{...}`, and a table with a `_tag` is prefixed with the tag (`_tag` and `_fxTagged` are not listed as fields).

```lua
print(Fx.inspect({ plate = 'ABC', seats = { 1, 2 } })) --> { plate = "ABC", seats = { [1] = 1, [2] = 2 } }
```

## Built-in core error tags

| Class | `_tag` | Raised by | Fields |
|---|---|---|---|
| `Fx.TimeoutError` | `'TimeoutError'` | `eff:timeout(ms)` | `timeoutMs` |
| `Fx.NoSuchElementError` | `'NoSuchElementError'` | `Fx.fromNullable(nil)` without `onNil` | none |
| `Fx.UnknownError` | `'UnknownError'` | `Fx.try` without `onError` | `message` (`tostring` of the raised error), `cause` (the raised value) |
| `Fx.ParseError` | `'ParseError'` | `schema:decode(input)`, `schema:parse(input)` ([Schema](core-schema.md)) | `message` (the schema message, for example `amount: expected integer, got "x"`) |

The FiveM modules declare their own tags (`RpcTimeout`, `AssetTimeout`, `SqlError`, `InsufficientFunds`, ...); see the [Errors catalogue](errors.md).

```lua
local exit = Fx.runSyncExit(Fx.try(function() error('lost connection', 0) end))
local e = Fx.Cause.failureOption(exit.cause)
print(e._tag, e.message, Fx.UnknownError.is(e)) --> UnknownError lost connection true
```

### What runSync and runAwait raise

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
