-- Stream: zero or more values over time, described once and run on demand.
--
--   Fx.security.stream()
--     :filter(function(ev) return ev.kind == 'invalid_payload' end)
--     :groupedWithin(50, 10000)
--     :runForEach(function(batch) return Webhook.post(batch) end)
--
-- A stream is a function run(emit) that returns an effect. emit(v) returns an
-- effect that succeeds with false when the consumer wants no more values. run
-- succeeds with true when the stream ended by itself and false when the
-- consumer stopped it. Nothing happens until a run* effect runs; running a
-- stream twice runs it twice. Values may be nil.
return function(Fx)
  local P = Fx._platform
  local succeed, failCause, unit = Fx.succeed, Fx.failCause, Fx.unit
  local isEffect = Fx.isEffect
  local Queue = Fx.Queue

  local CONTINUE = succeed(true)
  local ENDED, STOPPED = CONTINUE, succeed(false)

  -- Markers that travel through internal queues next to the values.
  local END = setmetatable({}, { __tostring = function() return 'Stream.END' end })
  local Failed = {} -- metatable of { cause }: a source failed
  local Tick = {}   -- metatable of { gen }: a deadline passed

  local Stream = {}
  Stream.__index = Stream
  Fx.Stream = Stream

  local function make(run) return setmetatable({ run = run }, Stream) end

  ---A stream from a raw run function (see the top of this file).
  Stream.fromRun = make

  function Stream.isStream(v) return getmetatable(v) == Stream end

  local function toEffect(r)
    if isEffect(r) then return r end
    return unit
  end

  -- q:take() without the async round trip when a value is already waiting.
  local function takeFrom(q)
    return Fx.suspend(function()
      if q:unsafeSize() > 0 then return succeed(q:unsafePoll()) end
      return q:take()
    end)
  end

  -- Feed what pull produces to emit until pull gives END or emit says stop.
  local function drive(pull, emit)
    local function step(v)
      if v == END then return ENDED end
      if getmetatable(v) == Failed then return failCause(v.cause) end
      return emit(v):flatMap(function(more)
        if more == false then return STOPPED end
        return pull:flatMap(step)
      end)
    end
    return pull:flatMap(step)
  end

  -- Emit what next() returns until it returns END.
  local function driveSync(next, emit)
    local function step()
      local v = next()
      if v == END then return ENDED end
      return emit(v):flatMap(function(more)
        if more == false then return STOPPED end
        return step()
      end)
    end
    return Fx.suspend(step)
  end

  ---------------------------------------------------------------------------
  -- Sources
  ---------------------------------------------------------------------------

  Stream.empty = make(function() return ENDED end)
  Stream.never = make(function() return Fx.never end)

  ---The given values, in order.
  function Stream.make(...)
    local args = table.pack(...)
    return make(function(emit)
      local i = 0
      return driveSync(function()
        i = i + 1
        if i > args.n then return END end
        return args[i]
      end, emit)
    end)
  end

  ---The items of a list, read when the stream runs.
  function Stream.fromTable(list)
    return make(function(emit)
      local i = 0
      return driveSync(function()
        i = i + 1
        if i > #list then return END end
        return list[i]
      end, emit)
    end)
  end

  ---from, from + 1, ..., to (inclusive). to defaults to forever.
  function Stream.range(from, to)
    to = to or math.huge
    return make(function(emit)
      local i = from - 1
      return driveSync(function()
        i = i + 1
        if i > to then return END end
        return i
      end, emit)
    end)
  end

  ---Start with seed and emit f(previous) forever.
  function Stream.iterate(seed, f)
    return make(function(emit)
      local v, first = seed, true
      return driveSync(function()
        if first then first = false else v = f(v) end
        return v
      end, emit)
    end)
  end

  function Stream.fail(err)
    return make(function() return Fx.fail(err) end)
  end

  ---One value: the result of eff.
  function Stream.fromEffect(eff)
    return make(function(emit) return eff:flatMap(emit) end)
  end

  ---Run eff again and again, emitting each result.
  function Stream.repeatEffect(eff)
    return make(function(emit) return drive(eff, emit) end)
  end

  ---Emit 1, 2, 3, ... with ms between them (the first after ms). The wait
  ---starts after the consumer has handled the previous value.
  function Stream.interval(ms)
    return make(function(emit)
      local n = 0
      return drive(Fx.sleep(ms):map(function() n = n + 1 return n end), emit)
    end)
  end

  ---Emit 1, 2, 3, ... following a schedule's delays, the first right away.
  function Stream.fromSchedule(schedule)
    return make(function(emit)
      local state, n = schedule.initial, 0
      local function step()
        n = n + 1
        return emit(n):flatMap(function(more)
          if more == false then return STOPPED end
          local cont, delay
          cont, delay, state = schedule.step(state, n, P.current.now())
          if not cont then return ENDED end
          if delay > 0 then return Fx.sleep(delay):zipRight(Fx.suspend(step)) end
          return step()
        end)
      end
      return Fx.suspend(step)
    end)
  end

  ---Everything taken from a Queue. Never ends by itself.
  function Stream.fromQueue(q)
    return make(function(emit) return drive(takeFrom(q), emit) end)
  end

  ---Every message published to a PubSub after the stream starts. Never
  ---ends by itself. opts as PubSub:subscribe (buffer, strategy).
  function Stream.fromPubSub(ps, opts)
    local capacity = opts and opts.buffer or math.huge
    local strategy = opts and opts.strategy or 'sliding'
    -- Not ps:subscribe(): its Scope would also reach the consumer, whose own
    -- finalizers would then run when this stream ends.
    return make(function(emit)
      return Fx.acquireUseRelease(
        Fx.sync(function()
          local q = Queue.unsafeMake(capacity, strategy)
          ps.subs[q] = true
          return q
        end),
        function(q) return drive(takeFrom(q), emit) end,
        function(q) return Fx.sync(function() ps.subs[q] = nil end) end)
    end)
  end

  ---Values pushed from plain callbacks (event handlers, exports, timers).
  ---register(push, finish) runs when the stream starts. push(v) is safe to
  ---call from anywhere; finish() ends the stream and finish(err) fails it.
  ---register may return a cleanup function, called however the stream ends.
  ---Values wait in a buffer while the consumer is busy: opts.buffer (default
  ---1024), and when it is full the oldest value is dropped (opts.strategy =
  ---'sliding', the default) or the newest ('dropping').
  function Stream.async(register, opts)
    local capacity = opts and opts.buffer or 1024
    local strategy = opts and opts.strategy or 'sliding'
    return make(function(emit)
      local q, closed, endMarker, cleanup
      local function push(v)
        if not closed then q:unsafeOffer(v) end
      end
      local function finish(err)
        if closed then return end
        closed = true
        endMarker = err == nil and END or setmetatable({ cause = Fx.Cause.fail(err) }, Failed)
        -- someone waiting means the buffer is empty
        if #q.takers > 0 then q:unsafeOffer(endMarker) end
      end
      local pull = Fx.suspend(function()
        if q:unsafeSize() > 0 then return succeed(q:unsafePoll()) end
        if endMarker then return succeed(endMarker) end
        return q:take()
      end)
      return Fx.sync(function()
        q = Queue.unsafeMake(capacity, strategy)
        cleanup = register(push, finish)
      end)
        :zipRight(Fx.suspend(function() return drive(pull, emit) end))
        :ensuring(Fx.sync(function()
          closed = true
          if type(cleanup) == 'function' then cleanup() end
        end))
    end)
  end

  ---A local event (AddEventHandler) as a stream. Each value is the first
  ---argument, or shape(...) when given; shape runs inside the handler, so
  ---`source` is set. The handler is registered while the stream runs.
  ---Net events from players should use Fx.net.stream, which validates them.
  ---opts.buffer and opts.strategy as in Stream.async.
  function Stream.event(name, shape, opts)
    return Stream.async(function(push)
      local h = AddEventHandler(name, function(...)
        if shape then push(shape(...)) else push((...)) end
      end)
      return function() RemoveEventHandler(h) end
    end, opts)
  end

  -- Run each source on its own fiber, feeding one bounded queue, and hand
  -- consume a pull effect over it (and the queue itself). The sources are interrupted when consume
  -- ends, however it ends. A failing source fails the pull.
  local function fanIn(sources, capacity, consume)
    return Fx.suspend(function()
      local q = Queue.unsafeMake(capacity, 'suspend')
      local live, fibers, closing = #sources, {}, false
      local function offer(v) return q:offer(v) end
      local function feed(src)
        return src.run(offer):exit():flatMap(function(exit)
          if exit._tag == 'Failure' then
            -- we interrupted it on the way out; a source that ends interrupted
            -- on its own still fails the stream instead of never ending
            if closing then return unit end
            return q:offer(setmetatable({ cause = exit.cause }, Failed))
          end
          live = live - 1
          if live == 0 then return q:offer(END) end
          return unit
        end)
      end
      local function forkAll(i)
        if i > #sources then return unit end
        return feed(sources[i]):fork():flatMap(function(f)
          fibers[i] = f
          return forkAll(i + 1)
        end)
      end
      local pull = takeFrom(q)
      if #sources == 0 then pull = succeed(END) end
      return forkAll(1)
        :zipRight(Fx.suspend(function() return consume(pull, q) end))
        :ensuring(Fx.suspend(function()
          closing = true
          return Fx.interruptAll(fibers)
        end))
    end)
  end

  ---Values from all streams as they arrive. Ends when every stream has
  ---ended; the first failure fails it and stops the rest.
  ---Also a method: a:merge(b, c).
  function Stream.merge(...)
    local sources = { ... }
    return make(function(emit)
      return fanIn(sources, 16, function(pull) return drive(pull, emit) end)
    end)
  end

  ---------------------------------------------------------------------------
  -- Operators
  ---------------------------------------------------------------------------

  function Stream:map(f)
    local src = self
    return make(function(emit)
      return src.run(function(v) return emit(f(v)) end)
    end)
  end

  ---f(v) returns an effect; its result is emitted. One at a time, in order.
  function Stream:mapEffect(f)
    local src = self
    return make(function(emit)
      return src.run(function(v) return f(v):flatMap(emit) end)
    end)
  end

  function Stream:filter(pred)
    local src = self
    return make(function(emit)
      return src.run(function(v)
        if pred(v) then return emit(v) end
        return CONTINUE
      end)
    end)
  end

  ---Emit f(v) when it is not nil.
  function Stream:filterMap(f)
    local src = self
    return make(function(emit)
      return src.run(function(v)
        local out = f(v)
        if out ~= nil then return emit(out) end
        return CONTINUE
      end)
    end)
  end

  ---Run f(v) (an effect, or nothing) before passing v on.
  function Stream:tap(f)
    local src = self
    return make(function(emit)
      return src.run(function(v)
        return toEffect(f(v)):flatMap(function() return emit(v) end)
      end)
    end)
  end

  ---The first n values, then stop.
  function Stream:take(n)
    local src = self
    return make(function(emit)
      if n <= 0 then return ENDED end
      local count, consumerStopped = 0, false
      return src.run(function(v)
        count = count + 1
        if count < n then return emit(v) end
        return emit(v):map(function(more)
          consumerStopped = more == false
          return false
        end)
      end):map(function(ended)
        if count >= n then return not consumerStopped end
        return ended
      end)
    end)
  end

  ---Values while pred holds; the first that fails it ends the stream.
  function Stream:takeWhile(pred)
    local src = self
    return make(function(emit)
      local cut = false
      return src.run(function(v)
        if pred(v) then return emit(v) end
        cut = true
        return STOPPED
      end):map(function(ended) return ended or cut end)
    end)
  end

  ---Values up to and including the first for which pred holds.
  function Stream:takeUntil(pred)
    local src = self
    return make(function(emit)
      local cut, consumerStopped = false, false
      return src.run(function(v)
        if not pred(v) then return emit(v) end
        cut = true
        return emit(v):map(function(more)
          consumerStopped = more == false
          return false
        end)
      end):map(function(ended)
        if cut then return not consumerStopped end
        return ended
      end)
    end)
  end

  function Stream:drop(n)
    local src = self
    return make(function(emit)
      local seen = 0
      return src.run(function(v)
        seen = seen + 1
        if seen > n then return emit(v) end
        return CONTINUE
      end)
    end)
  end

  function Stream:dropWhile(pred)
    local src = self
    return make(function(emit)
      local dropping = true
      return src.run(function(v)
        if dropping and pred(v) then return CONTINUE end
        dropping = false
        return emit(v)
      end)
    end)
  end

  ---Emit each running total: f(acc, v) for every v, starting from init.
  function Stream:scan(init, f)
    local src = self
    return make(function(emit)
      local acc = init
      return src.run(function(v)
        acc = f(acc, v)
        return emit(acc)
      end)
    end)
  end

  ---Skip values equal (==, or eq(a, b)) to the one before.
  function Stream:changes(eq)
    local src = self
    return make(function(emit)
      local has, last = false, nil
      return src.run(function(v)
        if has and (eq and eq(last, v) or (not eq and last == v)) then return CONTINUE end
        has, last = true, v
        return emit(v)
      end)
    end)
  end

  ---Lists of n values (the last may be shorter).
  function Stream:grouped(n)
    assert(n >= 1, 'Stream:grouped: n must be at least 1')
    local src = self
    return make(function(emit)
      local buf, k = {}, 0
      return src.run(function(v)
        k = k + 1
        buf[k] = v
        if k < n then return CONTINUE end
        local chunk = buf
        buf, k = {}, 0
        return emit(chunk)
      end):flatMap(function(ended)
        if ended and k > 0 then
          return emit(buf):map(function(more) return more ~= false end)
        end
        return succeed(ended)
      end)
    end)
  end

  -- A timer that posts a marker into q, for operators that wait on "a value
  -- or ms, whichever is first" without racing (a race could drop a value
  -- that arrives in the same tick as the timer). fired() is also true when
  -- the marker could not be queued because the queue was full.
  local function deadlineTimer(q)
    local gen, firedGen, cancel = 0, nil, nil
    local t = {}
    function t.arm(ms)
      if cancel then cancel() end
      gen = gen + 1
      local marker = setmetatable({ gen = gen }, Tick)
      cancel = P.current.setTimeout(ms, function()
        firedGen = marker.gen
        q:unsafeOffer(marker)
      end)
    end
    function t.disarm()
      if cancel then cancel() end
      cancel = nil
      gen = gen + 1
    end
    function t.fired() return firedGen == gen end
    function t.isCurrent(marker) return marker.gen == gen end
    return t
  end

  ---Lists of up to n values, emitted when full or ms after the first value
  ---of the list arrived, whichever is first. Good for batching writes.
  function Stream:groupedWithin(n, ms)
    assert(n >= 1, 'Stream:groupedWithin: n must be at least 1')
    local src = self
    return make(function(emit)
      return fanIn({ src }, 16, function(pull, q)
        local timer = deadlineTimer(q)
        local buf, k = {}, 0
        local loop
        local function flush()
          timer.disarm()
          local chunk = buf
          buf, k = {}, 0
          return emit(chunk):flatMap(function(more)
            if more == false then return STOPPED end
            return loop()
          end)
        end
        function loop()
          if k > 0 and timer.fired() then return flush() end
          return pull:flatMap(function(v)
            if v == END then
              timer.disarm()
              if k > 0 then return emit(buf):map(function(more) return more ~= false end) end
              return ENDED
            end
            if getmetatable(v) == Failed then return failCause(v.cause) end
            if getmetatable(v) == Tick then
              if k > 0 and timer.isCurrent(v) then return flush() end
              return loop()
            end
            k = k + 1
            buf[k] = v
            if k >= n then return flush() end
            if k == 1 then timer.arm(ms) end
            return loop()
          end)
        end
        return loop():ensuring(Fx.sync(timer.disarm))
      end)
    end)
  end

  ---Emit a value only once ms pass without a newer one (the newest wins).
  ---When the stream ends, a pending value is still emitted.
  function Stream:debounce(ms)
    local src = self
    return make(function(emit)
      return fanIn({ src }, 16, function(pull, q)
        local timer = deadlineTimer(q)
        local has, pending = false, nil
        local loop
        local function release()
          timer.disarm()
          local v = pending
          has, pending = false, nil
          return emit(v):flatMap(function(more)
            if more == false then return STOPPED end
            return loop()
          end)
        end
        function loop()
          if has and timer.fired() then return release() end
          return pull:flatMap(function(v)
            if v == END then
              timer.disarm()
              if has then return emit(pending):map(function(more) return more ~= false end) end
              return ENDED
            end
            if getmetatable(v) == Failed then return failCause(v.cause) end
            if getmetatable(v) == Tick then
              if has and timer.isCurrent(v) then return release() end
              return loop()
            end
            has, pending = true, v
            timer.arm(ms)
            return loop()
          end)
        end
        return loop():ensuring(Fx.sync(timer.disarm))
      end)
    end)
  end

  ---At most one value per ms: a value is dropped if the last one let
  ---through was less than ms ago.
  function Stream:throttle(ms)
    local src = self
    return make(function(emit)
      local last
      return src.run(function(v)
        local now = P.current.now()
        if last and now - last < ms then return CONTINUE end
        last = now
        return emit(v)
      end)
    end)
  end

  ---For each value, run the stream f(v) to its end before the next value.
  function Stream:flatMap(f)
    local src = self
    return make(function(emit)
      return src.run(function(v) return f(v).run(emit) end)
    end)
  end

  ---This stream, then that one.
  function Stream:concat(that)
    local src = self
    return make(function(emit)
      return src.run(emit):flatMap(function(ended)
        if not ended then return STOPPED end
        return that.run(emit)
      end)
    end)
  end

  ---If this stream fails with an expected error e, continue with f(e).
  ---Failures of the consumer are not caught.
  function Stream:catchAll(f)
    local src = self
    return make(function(emit)
      local consumerFailed = false
      return src.run(function(v)
        -- suspend: a consumer that raises (error(Tagged {})) fails here too
        return Fx.suspend(function() return emit(v) end):tapErrorCause(function() consumerFailed = true end)
      end):catchAllCause(function(cause)
        local e = Fx.Cause.failureOption(cause)
        if consumerFailed or e == nil then return failCause(cause) end
        return f(e).run(emit)
      end)
    end)
  end

  ---Run fin (an effect) when the stream stops, however it stops.
  function Stream:ensuring(fin)
    local src = self
    return make(function(emit) return src.run(emit):ensuring(fin) end)
  end

  ---End normally after ms. The source is stopped; a value the consumer is
  ---already handling is finished first.
  function Stream:interruptAfter(ms)
    local src = self
    return make(function(emit)
      return fanIn({ src }, 1, function(pull, q)
        local timer = deadlineTimer(q)
        timer.arm(ms)
        local function loop()
          if timer.fired() then return ENDED end
          return pull:flatMap(function(v)
            if v == END then return ENDED end
            if getmetatable(v) == Failed then return failCause(v.cause) end
            if getmetatable(v) == Tick then
              if timer.isCurrent(v) then return ENDED end
              return loop()
            end
            return emit(v):flatMap(function(more)
              if more == false then return STOPPED end
              return loop()
            end)
          end)
        end
        return loop():ensuring(Fx.sync(timer.disarm))
      end)
    end)
  end

  ---------------------------------------------------------------------------
  -- Running
  ---------------------------------------------------------------------------

  ---Run f(v) for every value; f may return an effect, which finishes before
  ---the next value. Succeeds when the stream ends.
  function Stream:runForEach(f)
    return self.run(function(v)
      local r = f(v)
      if isEffect(r) then return r:as(true) end
      return CONTINUE
    end):asVoid()
  end

  ---Like runForEach, but f returning false (or an effect of false) stops.
  function Stream:runForEachWhile(f)
    return self.run(function(v)
      local r = f(v)
      if isEffect(r) then return r:map(function(more) return more ~= false end) end
      return r == false and STOPPED or CONTINUE
    end):asVoid()
  end

  function Stream:runDrain()
    return self.run(function() return CONTINUE end):asVoid()
  end

  ---Succeed with every value in a list.
  function Stream:runCollect()
    local src = self
    return Fx.suspend(function()
      local out, k = {}, 0
      return src.run(function(v)
        k = k + 1
        out[k] = v
        return CONTINUE
      end):as(out)
    end)
  end

  function Stream:runFold(init, f)
    local src = self
    return Fx.suspend(function()
      local acc = init
      return src.run(function(v)
        acc = f(acc, v)
        return CONTINUE
      end):map(function() return acc end)
    end)
  end

  function Stream:runCount()
    return self:runFold(0, function(n) return n + 1 end)
  end

  ---The first value, or nil when the stream is empty.
  function Stream:runHead()
    local src = self
    return Fx.suspend(function()
      local first
      return src.run(function(v)
        first = v
        return STOPPED
      end):map(function() return first end)
    end)
  end

  ---The last value, or nil when the stream is empty.
  function Stream:runLast()
    return self:runFold(nil, function(_, v) return v end)
  end

  ---Start running on a new fiber; succeeds with the fiber at once.
  function Stream:runFork(f)
    return self:runForEach(f or function() end):fork()
  end
end
