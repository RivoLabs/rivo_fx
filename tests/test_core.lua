local T = ...
local test, eq, ok = T.test, T.eq, T.ok

test('succeed, map, flatMap', function()
  local Fx, p = T.fresh()
  local v = T.run(Fx, p, Fx.succeed(1):map(function(x) return x + 1 end):flatMap(function(x)
    return Fx.succeed(x * 10)
  end))
  eq(v, 20)
end)

test('catchAll recovers expected failures but not defects', function()
  local Fx, p = T.fresh()
  eq(T.run(Fx, p, Fx.fail('boom'):catchAll(function(e) return Fx.succeed('got ' .. e) end)), 'got boom')
  local exit = T.runExit(Fx, p, Fx.die('bug'):catchAll(function() return Fx.succeed('nope') end))
  eq(exit._tag, 'Failure')
  eq(Fx.Cause.defects(exit.cause)[1], 'bug')
end)

test('catchTag and catchTags match on _tag', function()
  local Fx, p = T.fresh()
  local NotFound = Fx.TaggedError('NotFound')
  local Busy = Fx.TaggedError('Busy')
  local v = T.run(Fx, p, NotFound { id = 7 }:fail()
    :catchTag('Busy', function() return Fx.succeed('busy') end)
    :catchTag('NotFound', function(e) return Fx.succeed('missing ' .. e.id) end))
  eq(v, 'missing 7')
  local exit = T.runExit(Fx, p, Busy {}:fail():catchTag('NotFound', function() return Fx.succeed(1) end))
  eq(Fx.Cause.failureOption(exit.cause)._tag, 'Busy')
  eq(T.run(Fx, p, Busy {}:fail():catchTags { Busy = function() return Fx.succeed('b') end }), 'b')
  ok(NotFound.is(NotFound {}))
  ok(not NotFound.is(Busy {}))
end)

test('mapError, orElseSucceed, result, option', function()
  local Fx, p = T.fresh()
  local exit = T.runExit(Fx, p, Fx.fail(1):mapError(function(e) return e + 1 end))
  eq(Fx.Cause.failureOption(exit.cause), 2)
  eq(T.run(Fx, p, Fx.fail(1):orElseSucceed(9)), 9)
  eq(T.run(Fx, p, Fx.fail('x'):result()), { ok = false, error = 'x' })
  eq(T.run(Fx, p, Fx.succeed(3):result()), { ok = true, value = 3 })
  eq(T.run(Fx, p, Fx.fail('x'):option()), nil)
end)

test('Fx.try turns thrown errors into UnknownError failures', function()
  local Fx, p = T.fresh()
  local exit = T.runExit(Fx, p, Fx.try(function() error('nope') end))
  local e = Fx.Cause.failureOption(exit.cause)
  eq(e._tag, 'UnknownError')
  T.match(e.message, 'nope')
  local exit2 = T.runExit(Fx, p, Fx.sync(function() error('bug') end))
  eq(#Fx.Cause.failures(exit2.cause), 0)
  T.match(tostring(Fx.Cause.defects(exit2.cause)[1]), 'bug')
end)

test('gen: direct style, failures short-circuit', function()
  local Fx, p = T.fresh()
  local reached = false
  local v = T.run(Fx, p, Fx.gen(function()
    local a = Fx.yield(Fx.succeed(2))
    local b = Fx.succeed(3):await()
    return a * b
  end))
  eq(v, 6)
  local exit = T.runExit(Fx, p, Fx.gen(function()
    Fx.yield(Fx.fail('stop'))
    reached = true
  end))
  eq(Fx.Cause.failureOption(exit.cause), 'stop')
  ok(not reached, 'code after a failed yield must not run')
end)

test('gen: error(TaggedError) fails, other errors are defects', function()
  local Fx, p = T.fresh()
  local Oops = Fx.TaggedError('Oops')
  local exit = T.runExit(Fx, p, Fx.gen(function() error(Oops { n = 1 }) end))
  eq(Fx.Cause.failureOption(exit.cause)._tag, 'Oops')
  local exit2 = T.runExit(Fx, p, Fx.gen(function() local x = nil; return x.y end))
  eq(#Fx.Cause.failures(exit2.cause), 0)
  T.match(tostring(Fx.Cause.defects(exit2.cause)[1]), 'attempt to index')
end)

test('gen: host yields (Citizen.Wait) pass through to the scheduler', function()
  local Fx, p = T.fresh()
  local v = T.run(Fx, p, Fx.gen(function()
    p.wait(250)
    return p.now()
  end))
  eq(v, 250)
end)

test('gen: host yields forward exactly the values yielded', function()
  -- FiveM reads the last value a thread yields; Wait(100) is a lone 100.
  local Fx, p = T.fresh()
  local seen = {}
  local spawn = p.spawn
  p.spawn = function(fn)
    spawn(function()
      local co = coroutine.create(fn)
      while true do
        local r = table.pack(coroutine.resume(co))
        if coroutine.status(co) == 'dead' then return end
        seen[#seen + 1] = r.n - 1
      end
    end)
  end
  T.run(Fx, p, Fx.gen(function() coroutine.yield(100) coroutine.yield(1, 2, 3) end))
  eq(seen, { 1, 3 })
end)

test('gen: args and nested gens', function()
  local Fx, p = T.fresh()
  local inner = function(x) return Fx.gen(function() Fx.yield(Fx.sleep(10)) return x + 1 end) end
  eq(T.run(Fx, p, Fx.gen(function(a, b)
    return Fx.yield(inner(a)) + Fx.yield(inner(b))
  end, 1, 2)), 5)
end)

test('Fx.yield outside gen raises a clear error', function()
  local Fx = T.fresh()
  local okCall, err = pcall(Fx.yield, Fx.succeed(1))
  ok(not okCall)
  T.match(err, 'outside Fx.gen')
end)

test('long flatMap chains do not grow the Lua stack', function()
  local Fx, p = T.fresh()
  local eff = Fx.succeed(0)
  for _ = 1, 100000 do eff = eff:map(function(x) return x + 1 end) end
  eq(T.run(Fx, p, eff), 100000)
  local function count(n) if n == 0 then return Fx.succeed('done') end
    return Fx.succeed(n):flatMap(function() return count(n - 1) end) end
  eq(T.run(Fx, p, count(200000)), 'done')
end)

test('sleep uses the platform clock', function()
  local Fx, p = T.fresh()
  T.run(Fx, p, Fx.sleep(1000):zipRight(Fx.sleep(500)))
  eq(p.now(), 1500)
end)

test('timeout fails with TimeoutError and interrupts the effect', function()
  local Fx, p = T.fresh()
  local cleaned = false
  local exit = T.runExit(Fx, p, Fx.sleep(5000):ensuring(Fx.sync(function() cleaned = true end)):timeout(100))
  eq(Fx.Cause.failureOption(exit.cause)._tag, 'TimeoutError')
  ok(cleaned, 'finalizer of the timed-out effect ran')
  eq(p.now(), 100)
  eq(T.run(Fx, p, Fx.succeed(5):delay(10):timeout(100)), 5)
  local start = p.now()
  local exit2 = T.runExit(Fx, p, Fx.fail('early'):delay(10):timeout(1000))
  eq(Fx.Cause.failureOption(exit2.cause), 'early', 'a failure inside the timeout wins over the timer')
  eq(p.now() - start, 10)
end)

test('raceFirst: the first to finish wins even when it fails', function()
  local Fx, p = T.fresh()
  local exit = T.runExit(Fx, p, Fx.fail('x'):delay(10):raceFirst(Fx.succeed('y'):delay(50)))
  eq(Fx.Cause.failureOption(exit.cause), 'x')
end)

test('ensuring/onExit run on success, failure and interruption', function()
  local Fx, p = T.fresh()
  local log = {}
  local function track(name)
    return function(exit) log[#log + 1] = name .. ':' .. exit._tag return Fx.unit end
  end
  T.runExit(Fx, p, Fx.succeed(1):onExit(track('a')))
  T.runExit(Fx, p, Fx.fail(1):onExit(track('b')))
  T.runExit(Fx, p, Fx.gen(function()
    local fiber = Fx.yield(Fx.never:onExit(track('c')):fork())
    Fx.yield(Fx.sleep(10))
    Fx.yield(fiber:interrupt())
  end))
  eq(log, { 'a:Success', 'b:Failure', 'c:Failure' })
end)

test('fork/join, and children are interrupted when the parent ends', function()
  local Fx, p = T.fresh()
  eq(T.run(Fx, p, Fx.succeed(4):delay(50):fork():flatMap(function(f) return f:join() end)), 4)
  local childStopped = false
  T.run(Fx, p, Fx.never:onInterrupt(function() childStopped = true return Fx.unit end):fork():zipLeft(Fx.sleep(10)))
  ok(childStopped, 'child interrupted when parent finished')
end)

test('forkDaemon outlives its parent', function()
  local Fx, p = T.fresh()
  local done = false
  T.run(Fx, p, Fx.sync(function() done = true end):delay(100):forkDaemon():asVoid())
  ok(done)
end)

test('uninterruptible regions finish before interruption lands', function()
  local Fx, p = T.fresh()
  local finished = false
  T.run(Fx, p, Fx.gen(function()
    local f = Fx.yield(Fx.sleep(100):zipRight(Fx.sync(function() finished = true end)):uninterruptible():fork())
    Fx.yield(Fx.sleep(10))
    local exit = Fx.yield(f:interrupt())
    eq(exit._tag, 'Failure')
  end))
  ok(finished, 'uninterruptible work completed')
  eq(p.now(), 100)
end)

test('race keeps the winner and interrupts the loser', function()
  local Fx, p = T.fresh()
  local loserStopped = false
  local v = T.run(Fx, p, Fx.succeed('slow'):delay(500):onInterrupt(function()
    loserStopped = true
    return Fx.unit
  end):race(Fx.succeed('fast'):delay(100)))
  eq(v, 'fast')
  ok(loserStopped)
  eq(T.run(Fx, p, Fx.fail('x'):race(Fx.succeed('y'):delay(10))), 'y')
end)

test('forEach runs concurrently and stops on first failure', function()
  local Fx, p = T.fresh()
  local items = { 300, 100, 200 }
  local v = T.run(Fx, p, Fx.forEach(items, function(ms) return Fx.succeed(ms):delay(ms) end, { concurrency = 'unbounded' }))
  eq(v, { 300, 100, 200 })
  eq(p.now(), 300)

  local Fx2, p2 = T.fresh()
  local interrupted = 0
  local exit = T.runExit(Fx2, p2, Fx2.forEach({ 1, 2, 3 }, function(i)
    if i == 2 then return Fx2.fail('bad'):delay(50) end
    return Fx2.never:onInterrupt(function() interrupted = interrupted + 1 return Fx2.unit end)
  end, { concurrency = 3 }))
  eq(Fx2.Cause.failureOption(exit.cause), 'bad')
  eq(interrupted, 2)
end)

test('forEach with bounded concurrency', function()
  local Fx, p = T.fresh()
  local active, peak = 0, 0
  T.run(Fx, p, Fx.forEach({ 1, 2, 3, 4, 5, 6 }, function()
    return Fx.sync(function() active = active + 1 peak = math.max(peak, active) end)
      :zipRight(Fx.sleep(100))
      :zipRight(Fx.sync(function() active = active - 1 end))
  end, { concurrency = 2 }))
  eq(peak, 2)
  eq(p.now(), 300)
end)

test('all with a record', function()
  local Fx, p = T.fresh()
  eq(T.run(Fx, p, Fx.all({ a = Fx.succeed(1), b = Fx.succeed(2) })), { a = 1, b = 2 })
  eq(T.run(Fx, p, Fx.all({ Fx.succeed(1), Fx.succeed(2) })), { 1, 2 })
  eq(T.run(Fx, p, Fx.all({})), {})
end)

test('retry follows the schedule and only retries expected failures', function()
  local Fx, p = T.fresh()
  local attempts = 0
  local flaky = Fx.suspend(function()
    attempts = attempts + 1
    if attempts < 3 then return Fx.fail('busy') end
    return Fx.succeed('ok')
  end)
  eq(T.run(Fx, p, flaky:retry(Fx.Schedule.exponential(100):take(5))), 'ok')
  eq(attempts, 3)
  eq(p.now(), 300) -- 100 + 200

  attempts = 0
  local exit = T.runExit(Fx, p, Fx.suspend(function() attempts = attempts + 1 return Fx.fail('x') end):retry(2))
  eq(attempts, 3)
  eq(exit._tag, 'Failure')

  attempts = 0
  T.runExit(Fx, p, Fx.suspend(function() attempts = attempts + 1 return Fx.die('bug') end):retry(5))
  eq(attempts, 1, 'defects are not retried')

  attempts = 0
  T.runExit(Fx, p, Fx.suspend(function() attempts = attempts + 1 return Fx.fail(attempts) end)
    :retry { times = 10, ['while'] = function(e) return e < 4 end })
  eq(attempts, 4)
end)

test('repeatN and repeatWith', function()
  local Fx, p = T.fresh()
  local n = 0
  T.run(Fx, p, Fx.sync(function() n = n + 1 end):repeatN(4))
  eq(n, 5)
  local start = p.now()
  n = 0
  T.run(Fx, p, Fx.sync(function() n = n + 1 end):repeatWith(Fx.Schedule.spaced(1000):take(2)))
  eq(n, 3)
  eq(p.now() - start, 2000)
end)

test('services: missing service is a clear defect, provideService works', function()
  local Fx, p = T.fresh()
  local Bank = Fx.Tag('Bank')
  local exit = T.runExit(Fx, p, Bank:flatMap(function(b) return Fx.succeed(b.name) end))
  T.match(Fx.Cause.defects(exit.cause)[1], 'Service not found: Bank')
  eq(T.run(Fx, p, Fx.gen(function() return Fx.yield(Bank).name end):provideService(Bank, { name = 'maze' })), 'maze')
end)

test('layers: dependencies, memoisation, scoped release', function()
  local Fx, p = T.fresh()
  local Db = Fx.Tag('Db')
  local Bank = Fx.Tag('Bank')
  local builds, released = 0, false
  local DbLive = Fx.Layer.scoped(Db, Fx.acquireRelease(
    Fx.sync(function() builds = builds + 1 return { query = function() return 42 end } end),
    function() return Fx.sync(function() released = true end) end))
  local BankLive = Fx.Layer.effect(Bank, Fx.gen(function()
    local db = Fx.yield(Db)
    return { balance = function() return db.query() end }
  end)):provide(DbLive)
  local App = Fx.Layer.merge(BankLive, DbLive)
  local v = T.run(Fx, p, Fx.gen(function()
    return Fx.yield(Bank).balance() + Fx.yield(Db).query()
  end):provide(App))
  eq(v, 84)
  eq(builds, 1, 'DbLive built once')
  ok(released, 'scoped layer released after use')
end)

test('Runtime builds its layer once and shares it', function()
  local Fx, p = T.fresh()
  local Counter = Fx.Tag('Counter')
  local builds = 0
  local rt = Fx.Runtime.make(Fx.Layer.sync(Counter, function() builds = builds + 1 return { n = 0 } end))
  local results = {}
  for i = 1, 3 do
    rt:runFork(Fx.gen(function()
      local c = Fx.yield(Counter)
      c.n = c.n + 1
      return c.n
    end), { onExit = function(e) results[i] = e.value end })
  end
  p.run()
  eq(builds, 1)
  eq(results, { 1, 2, 3 })
end)

test('scopes: acquireRelease releases in reverse order', function()
  local Fx, p = T.fresh()
  local log = {}
  local function res(name)
    return Fx.acquireRelease(Fx.sync(function() log[#log + 1] = '+' .. name return name end),
      function(a) return Fx.sync(function() log[#log + 1] = '-' .. a end) end)
  end
  T.run(Fx, p, Fx.scoped(Fx.gen(function()
    Fx.yield(res('a'))
    Fx.yield(res('b'))
    log[#log + 1] = 'use'
  end)))
  eq(log, { '+a', '+b', 'use', '-b', '-a' })
end)

test('resource stop closes open scopes synchronously and interrupts fibers', function()
  local Fx, p = T.fresh()
  local released, stopped = false, false
  Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.acquireRelease(Fx.succeed(1), function() return Fx.sync(function() released = true end) end))
    Fx.yield(Fx.never)
  end)))
  Fx.onStop(function() stopped = true end)
  p.run(10)
  ok(not released)
  -- what the onResourceStop handler does:
  Fx._interruptRoots()
  local n = Fx._closeAllScopes()
  ok(released, 'finalizer ran without another tick')
  ok(stopped, 'Fx.onStop ran')
  ok(n >= 2)
end)

test('runSync for sync effects, and a clear error for async ones', function()
  local Fx = T.fresh()
  eq(Fx.runSync(Fx.succeed(2):map(function(x) return x * 2 end)), 4)
  local Bad = Fx.TaggedError('Bad')
  local okCall, err = pcall(Fx.runSync, Bad { n = 1 }:fail())
  ok(not okCall)
  eq(err._tag, 'Bad')
  local okCall2, err2 = pcall(Fx.runSync, Fx.sleep(1))
  ok(not okCall2)
  T.match(err2, 'runSync hit an async effect')
end)

test('runAwait blocks a thread until the effect is done', function()
  local Fx, p = T.fresh()
  local got, caught
  p.spawn(function()
    got = Fx.runAwait(Fx.succeed('v'):delay(100))
    local okCall, e = pcall(Fx.runAwait, Fx.fail('nope'):delay(5))
    caught = (not okCall) and e
  end)
  p.run()
  eq(got, 'v')
  eq(caught, 'nope')
end)

test('Ref, Deferred, Semaphore, Queue', function()
  local Fx, p = T.fresh()
  local v = T.run(Fx, p, Fx.gen(function()
    local ref = Fx.yield(Fx.Ref.make(1))
    Fx.yield(ref:update(function(x) return x + 1 end))
    local d = Fx.yield(Fx.Deferred.make())
    Fx.yield(d:succeed('hi'):delay(50):fork())
    local msg = Fx.yield(d:await())
    local q = Fx.yield(Fx.Queue.bounded(1))
    Fx.yield(q:offer('a'))
    local putter = Fx.yield(q:offer('b'):fork()) -- waits for room
    local first = Fx.yield(q:take())
    Fx.yield(putter:join())
    local second = Fx.yield(q:take())
    return { Fx.yield(ref:get()), msg, first, second }
  end))
  eq(v, { 2, 'hi', 'a', 'b' })

  local active, peak = 0, 0
  T.run(Fx, p, Fx.gen(function()
    local sem = Fx.yield(Fx.Semaphore.make(1))
    Fx.yield(Fx.forEach({ 1, 2, 3 }, function()
      return sem:withPermit(Fx.sync(function() active = active + 1 peak = math.max(peak, active) end)
        :zipRight(Fx.sleep(10)):zipRight(Fx.sync(function() active = active - 1 end)))
    end, { concurrency = 'unbounded' }))
  end))
  eq(peak, 1)
end)

test('PubSub delivers to scoped subscribers and listeners', function()
  local Fx, p = T.fresh()
  local heard = {}
  local ps = Fx.PubSub.unsafeMake()
  ps:on(function(v) heard[#heard + 1] = v end)
  local v = T.run(Fx, p, Fx.scoped(Fx.gen(function()
    local q = Fx.yield(ps:subscribe())
    Fx.yield(ps:publish('x'))
    return Fx.yield(q:take())
  end)))
  eq(v, 'x')
  eq(heard, { 'x' })
  ps:unsafePublish('y')
  eq(next(ps.subs), nil, 'subscription removed when the scope closed')
end)

test('unhandled failures of root fibers are reported', function()
  local Fx, p = T.fresh()
  local reported
  Fx._reportUnhandled = function(_, cause) reported = Fx.Cause.pretty(cause) end
  Fx.runFork(Fx.fail('lost'))
  p.run()
  T.match(reported, 'Fail: lost')
end)

test('resource stop: attached and scoped fibers are interrupted without async defects', function()
  local Fx, p = T.fresh()
  local defects = {}
  Fx._reportDefect = function(where, err) defects[#defects + 1] = where .. ': ' .. tostring(err) end
  local scope = Fx.Scope.unsafeMake()
  local attached = Fx.runFork(Fx.never)
  scope:unsafeAttachFiber(attached)
  Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.never:forkScoped())
    Fx.yield(Fx.never)
  end)))
  p.run(10)
  Fx._interruptRoots()
  Fx._closeAllScopes()
  p.run()
  eq(defects, {})
  ok(attached.exit and Fx.Cause.isInterruptedOnly(attached.exit.cause))
end)

test('a parked root fiber survives garbage collection and is interrupted on stop', function()
  local Fx, p = T.fresh()
  local cleaned = false
  Fx.runFork(Fx.never:ensuring(Fx.sync(function() cleaned = true end)))
  p.run(10)
  collectgarbage('collect')
  collectgarbage('collect')
  eq(Fx._interruptRoots(), 1)
  p.run()
  ok(cleaned)
end)

test('Fx.logInfo and friends work before Fx.log is touched', function()
  local Fx = T.fresh()
  ok(rawget(Fx, 'log') == nil)
  for _, name in ipairs({ 'logDebug', 'logInfo', 'logWarn', 'logError' }) do
    ok(type(Fx[name]) == 'function', name)
  end
  ok(Fx.isEffect(Fx.logInfo('hello')))
end)
