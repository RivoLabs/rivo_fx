# Core schedule

This page covers `Fx.Schedule`, the policies that decide how often and with what delay an effect is retried after a failure (`eff:retry`) or repeated after a success (`eff:repeatWith`). Use it for database deadlocks, flaky HTTP calls, waiting for a resource to come up, autosaves and periodic jobs. For values over time, see [Streams](streams.md) (`Fx.Stream.fromSchedule`).

Examples print values with a `--> result` comment showing what they print.

## How a schedule works

A schedule is a table `{ initial = state, step = fun(state, input, now) }`. After each run of the effect, `step` is called with the current state, an input (the **error** for `retry`, the **value** for `repeatWith`) and the current game time in ms. It returns three values:

1. `continue` (boolean): run again?
2. `delayMs` (number): how long to wait before the next run (`0` runs again at once, without a tick in between);
3. `nextState`.

The first run always happens; the schedule only decides about the runs after it. Schedules are immutable values: each `retry` or `repeatWith` starts from `initial`, so one schedule can be shared by many effects.

## Constructors

### Fx.Schedule.spaced(ms) and Fx.Schedule.fixed(ms)

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

### Fx.Schedule.forever

```lua
Fx.Schedule.forever: Schedule
```

- **Notes:** continues forever with no delay. Combine it with `take`, `whileInput` or `upTo`, or the effect loops without waiting.

```lua
local n = 0
local count = Fx.sync(function() n = n + 1 return n end):repeatWith(Fx.Schedule.forever:take(4))
print(Fx.runSync(count)) --> 5
```

### Fx.Schedule.recurs(n) and Fx.Schedule.once

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

### Fx.Schedule.exponential(base, factor?)

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

### Fx.Schedule.fibonacci(base)

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

### Fx.Schedule.make(initial, step)

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

## Combinators

Every combinator returns a new schedule; the original is unchanged.

### schedule:take(n)

```lua
schedule:take(n: integer) -> Schedule
```

- **Returns:** the same delays, stopping after at most `n` recurrences. Same as `schedule:intersect(Fx.Schedule.recurs(n))`.

```lua
local attempts = 0
local eff = Fx.suspend(function() attempts = attempts + 1 return Fx.fail('busy') end)
Fx.runFork(eff:retry(Fx.Schedule.spaced(100):take(3)), { onExit = function() print(attempts) end }) --> 4
```

### schedule:intersect(other)

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

### schedule:union(other)

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

### schedule:jittered(min?, max?)

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

### schedule:maxDelay(ms)

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

### schedule:upTo(ms)

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

### schedule:whileInput(pred)

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

## Policies

`retry` and `repeatWith` accept:

| Policy | Meaning |
|---|---|
| a number `n` | `Fx.Schedule.recurs(n)`: `n` more runs, no delay |
| a `Schedule` | used as is |
| a table `{ schedule?, times?, while?, until? }` | `schedule` (default `Fx.Schedule.forever`), then `:take(times)`, then `:whileInput(while)`, then `:whileInput(not until(input))` |

`while` and `until` are Lua keywords, so write them as `['while']` and `['until']`. A table with only `while` or `until` and no `times` retries without limit and without delay while the predicate allows.

### eff:retry(policy)

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

### eff:repeatWith(schedule)

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

### eff:repeatN(n)

```lua
eff:repeatN(n: integer) -> Effect<A, E>
```

- **Returns:** an effect that runs `eff` `n + 1` times in total, with no delay, and succeeds with the last value.

```lua
local horn = 0
print(Fx.runSync(Fx.sync(function() horn = horn + 1 return horn end):repeatN(2))) --> 3
```
