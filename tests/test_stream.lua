local T = ...
local test, eq, ok = T.test, T.eq, T.ok

test('sources: make, fromTable, range, iterate, empty, fromEffect', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  eq(T.run(Fx, p, S.make(1, 2, 3):runCollect()), { 1, 2, 3 })
  eq(T.run(Fx, p, S.fromTable({ 'a', 'b' }):runCollect()), { 'a', 'b' })
  eq(T.run(Fx, p, S.range(3, 6):runCollect()), { 3, 4, 5, 6 })
  eq(T.run(Fx, p, S.iterate(1, function(x) return x * 2 end):take(5):runCollect()), { 1, 2, 4, 8, 16 })
  eq(T.run(Fx, p, S.empty:runCollect()), {})
  eq(T.run(Fx, p, S.fromEffect(Fx.succeed(7)):runCollect()), { 7 })
  eq(T.run(Fx, p, S.make(1, nil, 3):runCount()), 3, 'nil values are values')
end)

test('a stream runs again from the start each time', function()
  local Fx, p = T.fresh()
  local s = Fx.Stream.range(1, math.huge):map(function(x) return x * 10 end):take(2)
  eq(T.run(Fx, p, s:runCollect()), { 10, 20 })
  eq(T.run(Fx, p, s:runCollect()), { 10, 20 })
end)

test('pure operators', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local r = S.range(1, 10)
  eq(T.run(Fx, p, r:filter(function(x) return x % 2 == 0 end):map(function(x) return x * x end):runCollect()),
    { 4, 16, 36, 64, 100 })
  eq(T.run(Fx, p, r:filterMap(function(x) return x > 8 and -x or nil end):runCollect()), { -9, -10 })
  eq(T.run(Fx, p, r:takeWhile(function(x) return x < 4 end):runCollect()), { 1, 2, 3 })
  eq(T.run(Fx, p, r:takeUntil(function(x) return x == 4 end):runCollect()), { 1, 2, 3, 4 })
  eq(T.run(Fx, p, r:drop(8):runCollect()), { 9, 10 })
  eq(T.run(Fx, p, r:dropWhile(function(x) return x < 9 end):runCollect()), { 9, 10 })
  eq(T.run(Fx, p, S.make(1, 2, 3):scan(0, function(a, x) return a + x end):runCollect()), { 1, 3, 6 })
  eq(T.run(Fx, p, S.make(1, 1, 2, 2, 2, 1):changes():runCollect()), { 1, 2, 1 })
  eq(T.run(Fx, p, r:take(7):grouped(3):runCollect()), { { 1, 2, 3 }, { 4, 5, 6 }, { 7 } })
  eq(T.run(Fx, p, S.make(1, 2):concat(S.make(3)):runCollect()), { 1, 2, 3 })
  eq(T.run(Fx, p, S.make(1, 2):flatMap(function(x) return S.make(x, x) end):runCollect()), { 1, 1, 2, 2 })
  eq(T.run(Fx, p, r:runFold(0, function(a, x) return a + x end)), 55)
  eq(T.run(Fx, p, r:runHead()), 1)
  eq(T.run(Fx, p, r:runLast()), 10)
  eq(T.run(Fx, p, S.empty:runHead()), nil)
end)

test('take stops the source: nothing past n is produced', function()
  local Fx, p = T.fresh()
  local produced = 0
  local s = Fx.Stream.range(1):tap(function() produced = produced + 1 end)
  eq(T.run(Fx, p, s:take(3):runCollect()), { 1, 2, 3 })
  eq(produced, 3)
  -- an infinite stream inside flatMap and concat is cut too
  eq(T.run(Fx, p, Fx.Stream.make(1, 2):flatMap(function() return Fx.Stream.range(1) end):take(4):runCollect()),
    { 1, 2, 3, 4 })
  eq(T.run(Fx, p, Fx.Stream.range(1):concat(Fx.Stream.fail('never reached')):take(2):runCollect()), { 1, 2 })
end)

test('a stopped first stream does not start the second in concat', function()
  local Fx, p = T.fresh()
  local started = false
  local second = Fx.Stream.fromEffect(Fx.sync(function() started = true return 'x' end))
  eq(T.run(Fx, p, Fx.Stream.make(1, 2, 3):concat(second):take(2):runCollect()), { 1, 2 })
  ok(not started)
  eq(T.run(Fx, p, Fx.Stream.make(1):concat(second):take(2):runCollect()), { 1, 'x' })
end)

test('mapEffect and tap run effects in order', function()
  local Fx, p = T.fresh()
  local log = {}
  local v = T.run(Fx, p, Fx.Stream.make(1, 2, 3)
    :tap(function(x) log[#log + 1] = 'tap' .. x end)
    :mapEffect(function(x) return Fx.sleep(10):as(x * 2) end)
    :runCollect())
  eq(v, { 2, 4, 6 })
  eq(log, { 'tap1', 'tap2', 'tap3' })
  eq(p.now(), 30)
end)

test('failures: the stream fails, catchAll recovers, consumer failures are not caught', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local exit = T.runExit(Fx, p, S.make(1, 2):concat(S.fail('boom')):runCollect())
  eq(Fx.Cause.failureOption(exit.cause), 'boom')

  eq(T.run(Fx, p, S.make(1):concat(S.fail('boom')):catchAll(function(e) return S.make(e) end):runCollect()),
    { 1, 'boom' })

  local recovered = false
  local exit2 = T.runExit(Fx, p, S.make(1, 2):catchAll(function() recovered = true return S.empty end)
    :runForEach(function(x) if x == 2 then return Fx.fail('consumer') end end))
  eq(Fx.Cause.failureOption(exit2.cause), 'consumer')
  ok(not recovered, 'catchAll left the consumer failure alone')
end)

test('ensuring runs on end, stop and interruption', function()
  local Fx, p = T.fresh()
  local n = 0
  local fin = Fx.sync(function() n = n + 1 end)
  T.run(Fx, p, Fx.Stream.make(1, 2):ensuring(fin):runDrain())
  T.run(Fx, p, Fx.Stream.range(1):ensuring(fin):take(1):runDrain())
  T.runExit(Fx, p, Fx.Stream.never:ensuring(fin):runDrain():timeout(50))
  eq(n, 3)
end)

test('interval, fromSchedule and interruptAfter use the clock', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local start = p.now()
  eq(T.run(Fx, p, S.interval(100):take(3):runCollect()), { 1, 2, 3 })
  eq(p.now() - start, 300)

  start = p.now()
  eq(T.run(Fx, p, S.fromSchedule(Fx.Schedule.spaced(50):take(2)):runCollect()), { 1, 2, 3 })
  eq(p.now() - start, 100)

  start = p.now()
  eq(T.run(Fx, p, S.interval(100):interruptAfter(350):runCollect()), { 1, 2, 3 })
  eq(p.now() - start, 350)
end)

test('runForEachWhile stops when the callback returns false', function()
  local Fx, p = T.fresh()
  local seen = {}
  T.run(Fx, p, Fx.Stream.range(1):runForEachWhile(function(x)
    seen[#seen + 1] = x
    return x < 3
  end))
  eq(seen, { 1, 2, 3 })
end)

test('async: callbacks feed the stream, cleanup runs, finish ends it', function()
  local Fx, p = T.fresh()
  local pushFn, finishFn, cleaned = nil, nil, 0
  local s = Fx.Stream.async(function(push, finish)
    pushFn, finishFn = push, finish
    push('early') -- before anyone is waiting
    return function() cleaned = cleaned + 1 end
  end)
  local got
  Fx.runFork(s:runCollect(), { onExit = function(e) got = e end })
  p.setTimeout(10, function() pushFn('a') pushFn('b') end)
  p.setTimeout(20, function() finishFn() pushFn('ignored') end)
  p.run()
  eq(got.value, { 'early', 'a', 'b' })
  eq(cleaned, 1)

  -- finish(err) fails it; a consumer stopping early runs cleanup too
  Fx.runFork(s:runCollect(), { onExit = function(e) got = e end })
  p.setTimeout(5, function() finishFn('closed') end)
  p.run()
  eq(Fx.Cause.failureOption(got.cause), 'closed')
  eq(T.run(Fx, p, s:take(1):runCollect()), { 'early' })
  eq(cleaned, 3)
end)

test('async: a full buffer drops the oldest (sliding) or the newest (dropping)', function()
  local Fx, p = T.fresh()
  local function burst(strategy)
    local s = Fx.Stream.async(function(push, finish)
      for i = 1, 5 do push(i) end
      finish()
    end, { buffer = 2, strategy = strategy })
    return T.run(Fx, p, s:runCollect())
  end
  eq(burst('sliding'), { 4, 5 })
  eq(burst('dropping'), { 1, 2 })
end)

test('fromPubSub and fromQueue', function()
  local Fx, p = T.fresh()
  local ps = Fx.PubSub.unsafeMake()
  local got
  Fx.runFork(Fx.Stream.fromPubSub(ps):take(2):runCollect(), { onExit = function(e) got = e end })
  p.setTimeout(10, function() ps:unsafePublish('x') ps:unsafePublish('y') ps:unsafePublish('z') end)
  p.run()
  eq(got.value, { 'x', 'y' })
  eq(next(ps.subs), nil, 'unsubscribed when the stream stopped')

  local q = Fx.Queue.unsafeUnbounded()
  q:unsafeOffer(1)
  q:unsafeOffer(2)
  eq(T.run(Fx, p, Fx.Stream.fromQueue(q):take(2):runCollect()), { 1, 2 })
end)

test('merge interleaves by arrival and ends when all end', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local a = S.interval(30):map(function(i) return 'a' .. i end):take(3)
  local b = S.interval(50):map(function(i) return 'b' .. i end):take(2)
  eq(T.run(Fx, p, a:merge(b):runCollect()), { 'a1', 'b1', 'a2', 'a3', 'b2' })
  eq(p.now(), 100)
end)

test('merge: a failing source fails it and the others are interrupted', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local stopped = false
  local slow = S.never:ensuring(Fx.sync(function() stopped = true end))
  local exit = T.runExit(Fx, p, S.merge(slow, S.fromEffect(Fx.fail('bad'):delay(10))):runDrain())
  eq(Fx.Cause.failureOption(exit.cause), 'bad')
  ok(stopped)

  -- and stopping the merged stream interrupts every source
  stopped = false
  eq(T.run(Fx, p, S.merge(slow, S.make(1, 2, 3)):take(2):runCollect()), { 1, 2 })
  ok(stopped)
end)

test('debounce keeps the newest after a quiet gap and flushes at the end', function()
  local Fx, p = T.fresh()
  local push, finish
  local s = Fx.Stream.async(function(pu, fi) push, finish = pu, fi end)
  local got, at = {}, {}
  Fx.runFork(s:debounce(100):runForEach(function(v)
    got[#got + 1] = v
    at[#at + 1] = p.now()
  end))
  p.setTimeout(0, function() push(1) end)
  p.setTimeout(50, function() push(2) end)   -- replaces 1
  p.setTimeout(140, function() push(3) end)  -- replaces 2 (only 90 ms quiet)
  -- 3 goes out at 240
  p.setTimeout(400, function() push(4) end)
  p.setTimeout(420, function() finish() end) -- 4 is flushed when the stream ends
  p.run()
  eq(got, { 3, 4 })
  eq(at, { 240, 420 })
end)

test('debounce: a value arriving in the same tick as the deadline is not lost', function()
  local Fx, p = T.fresh()
  local push, finish
  local s = Fx.Stream.async(function(pu, fi) push, finish = pu, fi end)
  local got = {}
  Fx.runFork(s:debounce(100):runForEach(function(v) got[#got + 1] = v end))
  p.setTimeout(0, function() push('a') end)
  -- registered after the debounce timer for 'a', so both fire at 100 with the
  -- deadline first: 'b' lands while the deadline is being handled
  p.setTimeout(1, function() p.setTimeout(99, function() push('b') end) end)
  p.setTimeout(500, function() finish() end)
  p.run()
  eq(got, { 'a', 'b' })
end)

test('groupedWithin batches by size or time, whichever is first, and loses nothing', function()
  local Fx, p = T.fresh()
  local push, finish
  local s = Fx.Stream.async(function(pu, fi) push, finish = pu, fi end)
  local batches, at = {}, {}
  Fx.runFork(s:groupedWithin(3, 100):runForEach(function(b)
    batches[#batches + 1] = b
    at[#at + 1] = p.now()
  end))
  p.setTimeout(0, function() push(1) push(2) push(3) push(4) end) -- full batch at once, 4 starts the next
  p.setTimeout(30, function() push(5) end)
  -- [4, 5] goes at 100 (100 ms after 4 arrived)
  -- 6 lands in the same tick as that deadline, after it (registered later)
  p.setTimeout(1, function() p.setTimeout(99, function() push(6) end) end)
  p.setTimeout(250, function() push(7) finish() end)
  p.run()
  local all = {}
  for _, b in ipairs(batches) do
    ok(#b >= 1 and #b <= 3, 'batch size within 1..3')
    for _, v in ipairs(b) do all[#all + 1] = v end
  end
  eq(all, { 1, 2, 3, 4, 5, 6, 7 }, 'every value once, in order')
  eq(batches[1], { 1, 2, 3 })
  eq(batches[2], { 4, 5 })
  eq(at[1], 0)
  eq(at[2], 100)
end)

test('throttle lets one value through per window', function()
  local Fx, p = T.fresh()
  local got = T.run(Fx, p, Fx.Stream.interval(30):take(10):throttle(100):runCollect())
  -- values at 30, 60, ..., 300: kept at 30, 150 (120 ms later), 270
  eq(got, { 1, 5, 9 })
end)

test('a stream is interrupted with its fiber, and sources clean up', function()
  local Fx, p = T.fresh()
  local cleaned = false
  local s = Fx.Stream.async(function() return function() cleaned = true end end)
  local fiber = Fx.runFork(s:debounce(10):runDrain())
  p.run(50)
  ok(not cleaned)
  fiber:interruptAsFork(0)
  p.run()
  ok(cleaned, 'the source cleanup ran when the consuming fiber was interrupted')
  ok(fiber.exit and Fx.Cause.isInterruptedOnly(fiber.exit.cause))
end)

test('long streams do not grow the Lua stack', function()
  local Fx, p = T.fresh()
  eq(T.run(Fx, p, Fx.Stream.range(1, 100000):map(function(x) return x + 1 end)
    :filter(function(x) return x % 2 == 0 end):runCount()), 50000)
end)

test('catchAll leaves a consumer that raises alone', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local Boom = Fx.TaggedError('Boom')
  local recovered, seen = false, {}
  local s = S.make(1, 2, 3):catchAll(function() recovered = true return S.make('fallback') end)
  local exit = T.runExit(Fx, p, s:runForEach(function(v)
    seen[#seen + 1] = v
    if v == 2 then error(Boom {}) end
  end))
  eq(Fx.Cause.failureOption(exit.cause)._tag, 'Boom')
  eq(seen, { 1, 2 })
  ok(not recovered)
  -- a raise further down the pipeline, too
  local exit2 = T.runExit(Fx, p, s:filter(function(v) if v == 2 then error(Boom {}) end return true end):runDrain())
  eq(Fx.Cause.failureOption(exit2.cause)._tag, 'Boom')
  ok(not recovered)
end)

test("fromPubSub keeps its subscription out of the consumer's scope", function()
  local Fx, p = T.fresh()
  local ps = Fx.PubSub.unsafeMake()
  local finalizedAt
  T.run(Fx, p, Fx.scoped(Fx.gen(function()
    local f = Fx.yield(Fx.Stream.fromPubSub(ps):take(1):runForEach(function()
      return Fx.addFinalizer(function() return Fx.sync(function() finalizedAt = p.now() end) end)
    end):fork())
    Fx.yield(Fx.sleep(10))
    ps:unsafePublish('x')
    Fx.yield(f:join())
    Fx.yield(Fx.sleep(100))
  end)))
  eq(finalizedAt, 110, "the finalizer ran when the caller's scope closed, not when the stream ended")
  eq(next(ps.subs), nil)
end)

test('interruptAfter lets the value in hand finish and stops the source', function()
  local Fx, p = T.fresh()
  local log = {}
  local exit = T.runExit(Fx, p, Fx.Stream.make(1, 2):concat(Fx.Stream.never):interruptAfter(50):runForEach(function(v)
    return Fx.gen(function()
      log[#log + 1] = 'start ' .. v
      Fx.yield(Fx.sleep(100))
      log[#log + 1] = 'done ' .. v
    end)
  end))
  eq(exit._tag, 'Success')
  eq(log, { 'start 1', 'done 1' })
  eq(p.now(), 100)
end)

test('merge fails instead of hanging when a source ends interrupted on its own', function()
  local Fx, p = T.fresh()
  local S = Fx.Stream
  local selfInterrupted = S.fromEffect(Fx.gen(function()
    local f = Fx.yield(Fx.never:fork())
    Fx.yield(f:interrupt())
    return Fx.yield(f:join())
  end))
  local exit = T.runExit(Fx, p, S.merge(selfInterrupted, S.make(1)):runCollect(), 1000)
  ok(exit, 'merge finished')
  eq(exit._tag, 'Failure')
end)
