-- Effect, Cause, Exit, Fiber and the interpreter.
--
-- An Effect is an immutable description of a program. Nothing runs until a
-- fiber interprets it. The interpreter keeps its own continuation stack, so
-- long flatMap chains never grow the Lua call stack, and it suspends through
-- the platform so a waiting fiber costs nothing per tick.
return function(Fx)
  local P = Fx._platform

  local type, pcall, xpcall, setmetatable, select = type, pcall, xpcall, setmetatable, select
  local tostring, error, pairs, ipairs = tostring, error, pairs, ipairs
  local table_pack, table_unpack = table.pack, table.unpack
  local co_create, co_resume, co_yield, co_status, co_running, co_close =
    coroutine.create, coroutine.resume, coroutine.yield, coroutine.status, coroutine.running, coroutine.close
  local traceback = debug.traceback

  -- Effect opcodes
  local SUCCEED, FAIL, SYNC, ASYNC, FLATMAP, FOLD, SET_INTERRUPTIBLE, WITH_FIBER, PROVIDE, SERVICE, HOST_YIELD, YIELD_NOW =
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12

  -- Continuation frame kinds
  local K_MAP, K_FOLD, K_INTERRUPTIBLE, K_CONTEXT = 1, 2, 3, 4

  -- How many ops a fiber may run before it gives the frame back.
  local OPS_BEFORE_YIELD = 2048

  ---------------------------------------------------------------------------
  -- Cause
  ---------------------------------------------------------------------------

  local Cause = {}
  Fx.Cause = Cause

  Cause.empty = { _tag = 'Empty' }
  function Cause.fail(e) return { _tag = 'Fail', error = e } end
  function Cause.die(defect, trace) return { _tag = 'Die', defect = defect, trace = trace } end
  function Cause.interrupt(fiberId) return { _tag = 'Interrupt', fiberId = fiberId } end
  function Cause.sequential(l, r)
    if l._tag == 'Empty' then return r end
    if r._tag == 'Empty' then return l end
    return { _tag = 'Sequential', left = l, right = r }
  end
  function Cause.parallel(l, r)
    if l._tag == 'Empty' then return r end
    if r._tag == 'Empty' then return l end
    return { _tag = 'Parallel', left = l, right = r }
  end

  local function walk(c, fn)
    local t = c._tag
    if t == 'Sequential' or t == 'Parallel' then
      walk(c.left, fn)
      walk(c.right, fn)
    elseif t ~= 'Empty' then
      fn(c)
    end
  end
  Cause.walk = walk

  ---Expected errors in the cause, in order.
  function Cause.failures(c)
    local out = {}
    walk(c, function(n) if n._tag == 'Fail' then out[#out + 1] = n.error end end)
    return out
  end

  ---Defects (unexpected errors) in the cause, in order.
  function Cause.defects(c)
    local out = {}
    walk(c, function(n) if n._tag == 'Die' then out[#out + 1] = n.defect end end)
    return out
  end

  function Cause.isInterrupted(c)
    local found = false
    walk(c, function(n) if n._tag == 'Interrupt' then found = true end end)
    return found
  end

  ---True when the cause holds interruptions and nothing else.
  function Cause.isInterruptedOnly(c)
    local interrupt, other = false, false
    walk(c, function(n) if n._tag == 'Interrupt' then interrupt = true else other = true end end)
    return interrupt and not other
  end

  ---The first expected error, or nil.
  function Cause.failureOption(c)
    return Cause.failures(c)[1]
  end

  ---The most important thing in the cause: first failure, else first defect.
  function Cause.squash(c)
    local f = Cause.failures(c)[1]
    if f ~= nil then return f end
    local d = Cause.defects(c)[1]
    if d ~= nil then return d end
    if Cause.isInterrupted(c) then return 'interrupted' end
    return 'empty cause'
  end

  local function describe(v)
    if type(v) == 'table' then
      local mt = getmetatable(v)
      if mt and mt.__tostring then return tostring(v) end
      if v._tag then return Fx.inspect(v) end
    end
    return tostring(v)
  end
  Cause.describe = describe

  function Cause.pretty(c)
    local lines = {}
    walk(c, function(n)
      if n._tag == 'Fail' then
        lines[#lines + 1] = 'Fail: ' .. describe(n.error)
      elseif n._tag == 'Die' then
        lines[#lines + 1] = 'Defect: ' .. describe(n.defect) .. (n.trace and ('\n' .. n.trace) or '')
      elseif n._tag == 'Interrupt' then
        lines[#lines + 1] = 'Interrupted' .. (n.fiberId and (' by fiber #' .. tostring(n.fiberId)) or '')
      end
    end)
    return table.concat(lines, '\n')
  end

  ---------------------------------------------------------------------------
  -- Exit
  ---------------------------------------------------------------------------

  local Exit = {}
  Fx.Exit = Exit
  function Exit.succeed(v) return { _tag = 'Success', value = v } end
  function Exit.failCause(c) return { _tag = 'Failure', cause = c } end
  function Exit.isSuccess(e) return e._tag == 'Success' end
  function Exit.isFailure(e) return e._tag == 'Failure' end
  Exit.unit = Exit.succeed(nil)

  ---------------------------------------------------------------------------
  -- Effect
  ---------------------------------------------------------------------------

  local Effect = {}
  local EffectMT = { __index = Effect, __name = 'Fx.Effect' }
  EffectMT.__tostring = function() return 'Fx.Effect' end
  Fx.Effect = Effect
  Fx._EffectMT = EffectMT

  -- A table constructor sizes the hash part for every field it names, nil or
  -- not, so build only the fields in use. Most nodes have one or two.
  local function mk(op, a, b, c, d)
    if c == nil and d == nil then
      if b == nil then return setmetatable({ _op = op, a = a }, EffectMT) end
      return setmetatable({ _op = op, a = a, b = b }, EffectMT)
    end
    return setmetatable({ _op = op, a = a, b = b, c = c, d = d }, EffectMT)
  end
  Fx._mk = mk

  local function isEffect(v)
    return type(v) == 'table' and getmetatable(v) == EffectMT
  end
  Fx.isEffect = isEffect

  local function succeed(v) return mk(SUCCEED, v) end
  local function failCause(c) return mk(FAIL, c) end
  local unit = succeed(nil)

  ---Tagged errors thrown with error() inside a gen or sync become expected
  ---failures. Anything else thrown is a defect.
  local function fromThrown(err, trace)
    if type(err) == 'table' and err._fxTagged then
      return failCause(Cause.fail(err))
    end
    if type(err) == 'table' and err._fxCause then
      return failCause(err._fxCause)
    end
    return failCause(Cause.die(err, trace))
  end

  local function tracebackHandler(err)
    if type(err) == 'table' then return { err = err } end
    return { err = err, trace = traceback(nil, 2) }
  end

  ---Call f(...) and require it to return an effect; thrown errors become causes.
  local function callf(f, ...)
    local ok, res = xpcall(f, tracebackHandler, ...)
    if not ok then return fromThrown(res.err, res.trace) end
    if not isEffect(res) then
      return failCause(Cause.die('expected an Fx effect but got ' .. type(res) .. ' (' .. tostring(res) .. ')'))
    end
    return res
  end

  -- Constructors ------------------------------------------------------------

  ---@generic A
  ---@param value A
  ---@return Fx.Effect<A, never>
  function Fx.succeed(value) return succeed(value) end

  ---@generic E
  ---@param err E
  ---@return Fx.Effect<never, E>
  function Fx.fail(err) return failCause(Cause.fail(err)) end

  ---Fail with an unexpected error (a defect). Not caught by catchAll.
  function Fx.die(defect) return failCause(Cause.die(defect, traceback(nil, 2))) end

  function Fx.failCause(c) return failCause(c) end

  ---Lazily run a side effect. Errors thrown become defects (or failures for tagged errors).
  ---@generic A
  ---@param fn fun(): A
  ---@return Fx.Effect<A, never>
  function Fx.sync(fn) return mk(SYNC, fn) end

  ---Like sync, but thrown errors become expected `UnknownError` failures,
  ---or the result of onError(err) when given.
  function Fx.try(fn, onError)
    return mk(SYNC, function()
      local ok, res = pcall(fn)
      if ok then return res end
      if type(res) == 'table' and res._fxTagged then error(res, 0) end
      local e = onError and onError(res) or Fx.UnknownError { message = tostring(res), cause = res }
      error(e, 0)
    end)
  end

  ---Build the effect lazily.
  ---@param fn fun(): Fx.Effect
  function Fx.suspend(fn) return mk(SYNC, fn):flatMap(function(e) return e end) end

  ---Low-level callback effect. register(resume) gets a resume function that
  ---takes the effect to continue with. It may return a canceler function,
  ---called if the fiber is interrupted while waiting.
  ---@param register fun(resume: fun(e: Fx.Effect)): (fun()|nil)
  function Fx.async(register) return mk(ASYNC, register) end

  ---Callback that receives (ok, valueOrError) and succeeds or fails.
  function Fx.callback(register)
    return mk(ASYNC, function(resume)
      return register(function(ok, v)
        if ok then resume(succeed(v)) else resume(Fx.fail(v)) end
      end)
    end)
  end

  Fx.unit = unit
  Fx.void = unit

  Fx.never = mk(ASYNC, function() end)

  ---Give the frame back to the host scheduler once.
  Fx.yieldNow = mk(YIELD_NOW)

  ---@param ms integer
  ---@return Fx.Effect<nil, never>
  local function sleepRegister(resume, ms) return P.current.setTimeout(ms, resume, unit) end
  function Fx.sleep(ms)
    return mk(ASYNC, sleepRegister, ms)
  end

  function Fx.fromExit(exit)
    if exit._tag == 'Success' then return succeed(exit.value) end
    return failCause(exit.cause)
  end

  ---Fails with NoSuchElementError when value is nil.
  function Fx.fromNullable(v, onNil)
    if v == nil then return Fx.fail(onNil and onNil() or Fx.NoSuchElementError {}) end
    return succeed(v)
  end

  ---Wait for a Citizen promise (promise.new()). Rejections become failures.
  function Fx.fromPromise(p)
    return mk(ASYNC, function(resume)
      p:next(function(v) resume(succeed(v)) end, function(e) resume(Fx.fail(e)) end)
    end)
  end

  ---Access the running fiber.
  function Fx.withFiber(f) return mk(WITH_FIBER, f) end

  Fx.fiberId = mk(WITH_FIBER, function(fiber) return succeed(fiber.id) end)

  -- Combinators -------------------------------------------------------------

  ---@generic A, B, E
  ---@param self Fx.Effect<A, E>
  ---@param f fun(a: A): B
  ---@return Fx.Effect<B, E>
  function Effect:map(f)
    return mk(FLATMAP, self, function(a) return succeed(f(a)) end)
  end

  ---@generic A, B, E, E2
  ---@param self Fx.Effect<A, E>
  ---@param f fun(a: A): Fx.Effect<B, E2>
  ---@return Fx.Effect<B, E|E2>
  function Effect:flatMap(f) return mk(FLATMAP, self, f) end

  ---flatMap that also accepts a plain effect or a function returning a plain value.
  function Effect:andThen(f)
    if isEffect(f) then return mk(FLATMAP, self, function() return f end) end
    return mk(FLATMAP, self, function(a)
      local r = f(a)
      if isEffect(r) then return r end
      return succeed(r)
    end)
  end

  function Effect:as(v) return mk(FLATMAP, self, function() return succeed(v) end) end
  function Effect:asVoid() return self:as(nil) end

  ---Run f for its effect and keep the original value.
  function Effect:tap(f)
    return mk(FLATMAP, self, function(a)
      local r = f(a)
      if isEffect(r) then return r:as(a) end
      return succeed(a)
    end)
  end

  function Effect:zipRight(that) return mk(FLATMAP, self, function() return that end) end
  function Effect:zipLeft(that) return mk(FLATMAP, self, function(a) return that:as(a) end) end
  function Effect:zip(that)
    return mk(FLATMAP, self, function(a) return that:map(function(b) return { a, b } end) end)
  end

  ---Handle both outcomes on the full Cause. Skipped when the fiber is being interrupted.
  function Effect:foldCauseEffect(onFailure, onSuccess)
    return mk(FOLD, self, onFailure, onSuccess, 'catch')
  end

  function Effect:matchEffect(handlers)
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 then return failCause(c) end
      return handlers.onFailure(e)
    end, handlers.onSuccess)
  end

  function Effect:match(handlers)
    return self:matchEffect {
      onFailure = function(e) return succeed(handlers.onFailure(e)) end,
      onSuccess = function(a) return succeed(handlers.onSuccess(a)) end,
    }
  end

  ---Recover from any expected error. Defects and interruptions pass through.
  function Effect:catchAll(f)
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 then return failCause(c) end
      return f(e)
    end, nil)
  end

  ---Recover from any cause, including defects.
  function Effect:catchAllCause(f) return self:foldCauseEffect(f, nil) end

  ---Recover from defects only.
  function Effect:catchAllDefect(f)
    return self:foldCauseEffect(function(c)
      local d = Cause.defects(c)[1]
      if d == nil then return failCause(c) end
      return f(d)
    end, nil)
  end

  ---Recover from errors whose _tag equals tag.
  ---@param tag string
  ---@param f fun(e: any): Fx.Effect
  function Effect:catchTag(tag, f)
    return self:catchIf(function(e) return type(e) == 'table' and e._tag == tag end, f)
  end

  ---Recover from several tags: eff:catchTags { NotFound = fn, Timeout = fn }
  function Effect:catchTags(handlers)
    return self:catchIf(function(e) return type(e) == 'table' and handlers[e._tag] ~= nil end,
      function(e) return handlers[e._tag](e) end)
  end

  function Effect:catchIf(pred, f)
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 or not pred(e) then return failCause(c) end
      return f(e)
    end, nil)
  end

  function Effect:mapError(f)
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 then return failCause(c) end
      return Fx.fail(f(e))
    end, nil)
  end

  function Effect:tapError(f)
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 then return failCause(c) end
      local r = f(e)
      if isEffect(r) then return r:zipRight(failCause(c)) end
      return failCause(c)
    end, nil)
  end

  function Effect:tapErrorCause(f)
    return self:foldCauseEffect(function(c)
      local r = f(c)
      if isEffect(r) then return r:zipRight(failCause(c)) end
      return failCause(c)
    end, nil)
  end

  function Effect:orElse(f) return self:catchAll(function() return f() end) end
  function Effect:orElseSucceed(v) return self:catchAll(function() return succeed(v) end) end

  ---Turn expected errors into defects.
  function Effect:orDie()
    return self:catchAll(function(e) return failCause(Cause.die(e)) end)
  end

  ---Succeed with { ok = true, value = a } or { ok = false, error = e }.
  function Effect:result()
    return self:foldCauseEffect(function(c)
      local e = Cause.failureOption(c)
      if e == nil or #Cause.defects(c) > 0 then return failCause(c) end
      return succeed({ ok = false, error = e })
    end, function(a) return succeed({ ok = true, value = a }) end)
  end

  ---Succeed with the value, or nil on expected failure.
  function Effect:option() return self:orElseSucceed(nil) end

  ---Succeed with the Exit, never fail. Interruption still propagates.
  function Effect:exit()
    return self:foldCauseEffect(function(c) return succeed(Exit.failCause(c)) end,
      function(a) return succeed(Exit.succeed(a)) end)
  end

  function Effect:filterOrFail(pred, onFalse)
    return self:flatMap(function(a)
      if pred(a) then return succeed(a) end
      return Fx.fail(onFalse(a))
    end)
  end

  function Effect:delay(ms) return Fx.sleep(ms):zipRight(self) end

  function Effect:forever()
    local loop
    loop = function() return self:flatMap(loop) end
    return loop()
  end

  -- Interruptibility ---------------------------------------------------------

  function Effect:uninterruptible() return mk(SET_INTERRUPTIBLE, self, false) end
  function Effect:interruptible() return mk(SET_INTERRUPTIBLE, self, true) end

  ---f(restore) runs uninterruptibly; restore(e) brings back the outer interruptibility for e.
  function Fx.uninterruptibleMask(f)
    return mk(WITH_FIBER, function(fiber)
      local outer = fiber.interruptible
      local function restore(e) return mk(SET_INTERRUPTIBLE, e, outer) end
      return mk(SET_INTERRUPTIBLE, Fx.suspend(function() return f(restore) end), false)
    end)
  end

  ---Run fin(exit) after self, whatever happened (success, failure, interruption).
  ---fin runs uninterruptibly.
  function Effect:onExit(fin)
    local inner = self
    return Fx.uninterruptibleMask(function(restore)
      return mk(FOLD, restore(inner), function(c)
        return callf(fin, Exit.failCause(c)):foldCauseEffect(function(c2)
          return failCause(Cause.sequential(c, c2))
        end, function() return failCause(c) end)
      end, function(a)
        return callf(fin, Exit.succeed(a)):as(a)
      end, 'exit')
    end)
  end

  ---Internal: call fn(exit) after self, however it ends, for bookkeeping
  ---that is plain synchronous Lua (closing a span, recording a metric). One
  ---frame instead of onExit's uninterruptible region, so it is cheap enough
  ---to wrap every RPC and net handler. fn must not yield. If it raises, the
  ---error is added to the cause as onExit does, so an interruption stays an
  ---interruption.
  function Fx._onExitSync(eff, fn)
    return mk(FOLD, eff, function(c)
      local ok, err = pcall(fn, Exit.failCause(c))
      if not ok then return failCause(Cause.sequential(c, Cause.die(err))) end
      return failCause(c)
    end, function(a)
      local ok, err = pcall(fn, Exit.succeed(a))
      if not ok then return failCause(Cause.die(err)) end
      return succeed(a)
    end, 'exit')
  end

  ---Run finalizer (an effect) after self in every case.
  function Effect:ensuring(finalizer)
    return self:onExit(function() return finalizer end)
  end

  function Effect:onError(f)
    return self:onExit(function(exit)
      if exit._tag == 'Failure' then return f(exit.cause) end
      return unit
    end)
  end

  function Effect:onInterrupt(f)
    return self:onExit(function(exit)
      if exit._tag == 'Failure' and Cause.isInterrupted(exit.cause) then return f() end
      return unit
    end)
  end

  ---acquire, use, release. release(a, exit) always runs, uninterruptibly.
  function Fx.acquireUseRelease(acquire, use, release)
    return Fx.uninterruptibleMask(function(restore)
      return acquire:flatMap(function(a)
        return restore(Fx.suspend(function() return use(a) end)):onExit(function(exit)
          return release(a, exit)
        end)
      end)
    end)
  end

  -- Context / services -------------------------------------------------------


  ---Declare a service. The tag itself is an effect that yields the service.
  ---@param key string
  ---@return Fx.Tag
  function Fx.Tag(key)
    local tag = setmetatable({ _op = SERVICE, key = key }, EffectMT)
    tag.a = tag
    return tag
  end

  function Fx.isTag(v) return isEffect(v) and v._op == SERVICE end

  ---The service for tag if one is provided, else nil (never fails).
  function Fx.serviceOption(tag)
    return mk(WITH_FIBER, function(fiber) return succeed(fiber.context[tag]) end)
  end

  local Context = {}
  Fx.Context = Context
  function Context.empty() return {} end
  function Context.add(ctx, tag, service)
    local out = {}
    for k, v in pairs(ctx) do out[k] = v end
    out[tag] = service
    return out
  end
  function Context.merge(a, b)
    local out = {}
    for k, v in pairs(a) do out[k] = v end
    for k, v in pairs(b) do out[k] = v end
    return out
  end
  function Context.get(ctx, tag) return ctx[tag] end

  ---Provide a single service to self.
  function Effect:provideService(tag, service)
    return mk(PROVIDE, self, function(ctx) return Context.add(ctx, tag, service) end)
  end

  ---Provide a whole context (tag -> service table) to self.
  function Effect:provideContext(ctx)
    return mk(PROVIDE, self, function(outer) return Context.merge(outer, ctx) end)
  end

  -- Gen ---------------------------------------------------------------------

  local GEN = {}
  local genCoroutines = setmetatable({}, { __mode = 'k' })

  ---Write effectful code in direct style:
  ---  Fx.gen(function()
  ---    local player = Fx.yield(Players.get(src))
  ---    return player.name
  ---  end)
  ---Citizen.Wait and Citizen.Await still work inside the body.
  ---@generic A
  ---@param body fun(...): A
  ---@return Fx.Effect<A, any>
  function Fx.gen(body, ...)
    local args = table_pack(...)
    return mk(SYNC, function()
      local co = co_create(body)
      genCoroutines[co] = true
      return co
    end):flatMap(function(co)
      local step
      local function handle(ok, a, ...)
        if not ok then
          local trace = type(a) ~= 'table' and traceback(co, tostring(a)) or nil
          return fromThrown(a, trace)
        end
        if co_status(co) == 'dead' then return succeed(a) end
        if a == GEN then
          local eff = ...
          if not isEffect(eff) then
            return failCause(Cause.die('Fx.yield expects an effect, got ' .. type(eff)))
          end
          return mk(FLATMAP, eff, step)
        end
        -- Something else yielded (Citizen.Wait, Citizen.Await): pass exactly
        -- those values to the host. FiveM reads the last one, so a padded
        -- trailing nil would turn Wait(100) into Wait(0).
        return mk(FLATMAP, mk(HOST_YIELD, table_pack(a, ...)), function(r)
          return step(table_unpack(r, 1, r.n))
        end)
      end
      step = function(...) return handle(co_resume(co, ...)) end
      return mk(FLATMAP, step(table_unpack(args, 1, args.n)), succeed):onExit(function()
        if co_status(co) == 'suspended' then co_close(co) end
        return unit
      end)
    end)
  end

  ---Run eff inside an Fx.gen body and return its value. On failure the body
  ---stops here and the gen fails with the same cause.
  ---@generic A
  ---@param eff Fx.Effect<A, any>
  ---@return A
  function Fx.yield(eff)
    local co = co_running()
    if not genCoroutines[co] then
      error('Fx.yield called outside Fx.gen. Wrap the code in Fx.gen(function() ... end), or use Fx.runAwait from a thread.', 2)
    end
    return co_yield(GEN, eff)
  end

  ---Method form of Fx.yield, for use inside Fx.gen.
  function Effect:await() return Fx.yield(self) end

  ---------------------------------------------------------------------------
  -- Fiber
  ---------------------------------------------------------------------------

  local Fiber = {}
  Fiber.__index = Fiber
  Fx.Fiber = Fiber

  local nextFiberId = 0
  -- Strong refs: a fiber parked on Fx.never is reachable from nothing else.
  local rootFibers = {}
  Fx._rootFibers = rootFibers

  function Fiber.new(effect, context, parent)
    nextFiberId = nextFiberId + 1
    local f = setmetatable({
      id = nextFiberId,
      born = P.current.now(),
      effect = effect,
      context = context or {},
      parent = parent,
      children = {},
      observers = {},
      interruptible = true,
      interrupting = false,
      interruptRequested = nil,
    }, Fiber)
    if parent then parent.children[f] = true end
    return f
  end

  function Fiber:start()
    P.current.spawn(function() self:run(false) end)
    return self
  end

  function Fiber:addObserver(cb)
    if self.exit then cb(self.exit) return function() end end
    local obs = self.observers
    obs[#obs + 1] = cb
    return function()
      for i = #obs, 1, -1 do if obs[i] == cb then table.remove(obs, i) end end
    end
  end

  ---Request interruption without waiting for it to finish.
  function Fiber:interruptAsFork(byId)
    if self.exit or self.interruptRequested then return end
    self.interruptRequested = Cause.interrupt(byId)
    if self.interruptible and self.asyncResume then
      local cancel = self.asyncCanceler
      self.asyncCanceler = nil
      if cancel then pcall(cancel) end -- a function or a callable table
      self.asyncResume(unit)
    end
  end

  ---Effect that waits for the fiber and succeeds with its Exit.
  function Fiber:await()
    local target = self
    return mk(ASYNC, function(resume)
      return target:addObserver(function(exit) resume(succeed(exit)) end)
    end)
  end

  ---Effect that waits for the fiber and continues with its result.
  function Fiber:join()
    return self:await():flatMap(Fx.fromExit)
  end

  ---Effect that interrupts the fiber and waits until it has stopped.
  function Fiber:interrupt()
    local target = self
    return mk(WITH_FIBER, function(me)
      target:interruptAsFork(me.id)
      return target:await()
    end)
  end

  ---Run register(resume, arg) and park the fiber until resume is
  ---called. This is the hot path of every Fx.sleep and async wait, so the
  ---only allocation is the resume closure. suspendGen gives each suspension
  ---its own identity: a resume left over from an earlier one is ignored.
  function Fiber:suspendOn(register, arg)
    local gen = (self.suspendGen or 0) + 1
    self.suspendGen = gen
    self.asyncDone = false
    local function resume(eff)
      if self.suspendGen ~= gen or self.asyncDone then return end
      self.asyncDone = true
      self.asyncValue = eff
      self.asyncResume = nil
      self.asyncCanceler = nil
      if self.parked then P.current.unpark(self) end
    end
    self.asyncResume = resume
    local ok, canceler = pcall(register, resume, arg)
    if not ok then
      resume(failCause(Cause.die(canceler)))
    elseif not self.asyncDone then
      self.asyncCanceler = canceler
      -- interrupted before we got here
      if self.interruptRequested and self.interruptible then
        if canceler then pcall(canceler) end
        resume(unit)
      end
    end
    if not self.asyncDone then
      self.parked = true
      P.current.park(self)
      self.parked = false
    end
    local value = self.asyncValue
    self.asyncValue = nil
    if not isEffect(value) then value = succeed(value) end
    return value
  end

  function Fiber:done(exit)
    self.exit = exit
    self.effect = nil
    rootFibers[self] = nil
    if self.parent then self.parent.children[self] = nil end
    for child in pairs(self.children) do child:interruptAsFork(self.id) end
    local obs = self.observers
    self.observers = {}
    for i = 1, #obs do
      local ok, err = pcall(obs[i], exit)
      if not ok then Fx._reportDefect('fiber observer', err) end
    end
    if self.reportUnhandled and #obs == 0 and exit._tag == 'Failure'
      and not Cause.isInterruptedOnly(exit.cause) then
      Fx._reportUnhandled(self, exit.cause)
    end
    return exit
  end

  ---The interpreter. sync = true forbids suspending (runSync).
  function Fiber:run(sync)
    local cur = self.effect
    -- Continuation stack as parallel arrays (no table per frame):
    -- fk = kind, fa/fb/fc = K_MAP f | K_FOLD onFailure, onSuccess, kind | K_INTERRUPTIBLE, K_CONTEXT prev
    local fk, fa, fb, fc, sp = {}, {}, {}, {}, 0
    local ops = 0

    while true do
      if self.interruptRequested and not self.interrupting and self.interruptible then
        self.interrupting = true
        cur = failCause(self.interruptRequested)
      end

      ops = ops + 1
      if ops > OPS_BEFORE_YIELD then
        ops = 0
        if not sync then P.current.yieldNow() end
      end

      local op = cur._op

      if op == SUCCEED then
        local v = cur.a
        local nxt
        while sp > 0 do
          local k, a = fk[sp], fa[sp]
          fa[sp] = nil
          if k == K_MAP then
            sp = sp - 1
            nxt = callf(a, v)
            break
          elseif k == K_FOLD then
            local onSuccess = fb[sp]
            fb[sp], fc[sp] = nil, nil
            sp = sp - 1
            if onSuccess then
              nxt = callf(onSuccess, v)
              break
            end
          elseif k == K_INTERRUPTIBLE then
            sp = sp - 1
            self.interruptible = a
            -- leaving an uninterruptible region: a pending interruption lands now
            if a and self.interruptRequested and not self.interrupting then
              self.interrupting = true
              nxt = failCause(self.interruptRequested)
              break
            end
          else -- K_CONTEXT
            sp = sp - 1
            self.context = a
          end
        end
        if not nxt then return self:done(Exit.succeed(v)) end
        cur = nxt

      elseif op == FAIL then
        local c = cur.a
        local nxt
        while sp > 0 do
          local k, a = fk[sp], fa[sp]
          fa[sp] = nil
          if k == K_FOLD then
            local kind = fc[sp]
            fb[sp], fc[sp] = nil, nil
            sp = sp - 1
            -- While unwinding an interruption only finalizers run; failures
            -- inside a finalizer can still be caught normally.
            if kind == 'exit' or not (self.interrupting and Cause.isInterrupted(c)) then
              nxt = callf(a, c)
              break
            end
          else
            sp = sp - 1
            if k == K_INTERRUPTIBLE then
              self.interruptible = a
            elseif k == K_CONTEXT then
              self.context = a
            end
          end
        end
        if not nxt then return self:done(Exit.failCause(c)) end
        cur = nxt

      elseif op == FLATMAP then
        sp = sp + 1
        fk[sp], fa[sp] = K_MAP, cur.b
        cur = cur.a

      elseif op == FOLD then
        sp = sp + 1
        fk[sp], fa[sp], fb[sp], fc[sp] = K_FOLD, cur.b, cur.c, cur.d
        cur = cur.a

      elseif op == SYNC then
        local ok, res = xpcall(cur.a, tracebackHandler)
        if ok then cur = succeed(res) else cur = fromThrown(res.err, res.trace) end

      elseif op == SERVICE then
        local s = self.context[cur.a]
        if s == nil then
          cur = failCause(Cause.die('Service not found: ' .. tostring(cur.a.key)
            .. '. Provide it with :provide(layer) or :provideService(tag, impl).'))
        else
          cur = succeed(s)
        end

      elseif op == SET_INTERRUPTIBLE then
        local flag = cur.b
        if flag ~= self.interruptible then
          sp = sp + 1
          fk[sp], fa[sp] = K_INTERRUPTIBLE, self.interruptible
          self.interruptible = flag
        end
        cur = cur.a

      elseif op == PROVIDE then
        sp = sp + 1
        fk[sp], fa[sp] = K_CONTEXT, self.context
        self.context = cur.b(self.context)
        cur = cur.a

      elseif op == WITH_FIBER then
        cur = callf(cur.a, self)

      elseif op == ASYNC then
        if sync then
          cur = failCause(Cause.die('Fx.runSync hit an async effect. Use Fx.runFork or Fx.runAwait instead.'))
        else
          cur = self:suspendOn(cur.a, cur.b)
        end

      elseif op == HOST_YIELD then
        if sync then
          cur = failCause(Cause.die('Fx.runSync hit Citizen.Wait/Await inside Fx.gen. Use Fx.runFork or Fx.runAwait instead.'))
        else
          local vals = cur.a
          cur = succeed(table_pack(co_yield(table_unpack(vals, 1, vals.n))))
        end

      elseif op == YIELD_NOW then
        if not sync then P.current.yieldNow() end
        cur = unit

      else
        cur = failCause(Cause.die('not an Fx effect: ' .. tostring(cur)))
      end
    end
  end

  -- Forking -----------------------------------------------------------------

  ---Run self on a child fiber. The child is interrupted when the parent finishes.
  function Effect:fork()
    local eff = self
    return mk(WITH_FIBER, function(parent)
      return succeed(Fiber.new(eff, parent.context, parent):start())
    end)
  end

  ---Run self on a fiber that outlives its parent. It is still interrupted on resource stop.
  function Effect:forkDaemon()
    local eff = self
    return mk(WITH_FIBER, function(parent)
      local f = Fiber.new(eff, parent.context, nil)
      f.reportUnhandled = true
      rootFibers[f] = true
      return succeed(f:start())
    end)
  end

  ---Wait for every fiber in the list to stop after interrupting them.
  function Fx.interruptAll(fibers)
    return mk(WITH_FIBER, function(me)
      for _, f in ipairs(fibers) do f:interruptAsFork(me.id) end
      return Fx.forEach(fibers, function(f) return f:await() end):asVoid()
    end)
  end

  ---------------------------------------------------------------------------
  -- Concurrency combinators
  ---------------------------------------------------------------------------

  ---Run both, keep the first to succeed, interrupt the other.
  ---Fails only if both fail.
  function Effect:race(that)
    return Fx.raceAll({ self, that })
  end

  function Fx.raceAll(effects)
    return mk(WITH_FIBER, function(parent)
      return mk(ASYNC, function(resume)
        local fibers, settled, failures = {}, false, {}
        for i, eff in ipairs(effects) do
          fibers[i] = Fiber.new(eff, parent.context, parent)
        end
        for i, f in ipairs(fibers) do
          f:addObserver(function(exit)
            if settled then return end
            if exit._tag == 'Success' then
              settled = true
              local losers = {}
              for j, g in ipairs(fibers) do if j ~= i then losers[#losers + 1] = g end end
              resume(Fx.interruptAll(losers):as(exit.value))
            else
              failures[#failures + 1] = exit.cause
              if #failures == #fibers then
                settled = true
                local c = Cause.empty
                for _, fc in ipairs(failures) do c = Cause.parallel(c, fc) end
                resume(failCause(c))
              end
            end
          end)
        end
        for _, f in ipairs(fibers) do f:start() end
        return function()
          for _, f in ipairs(fibers) do f:interruptAsFork(parent.id) end
        end
      end)
    end)
  end

  ---Run both; whichever finishes first (success or failure) decides the result.
  ---The other is interrupted.
  function Effect:raceFirst(that)
    return self:exit():race(that:exit()):flatMap(Fx.fromExit)
  end

  ---Fail with TimeoutError if self takes longer than ms. self is interrupted.
  function Effect:timeout(ms)
    return self:timeoutFail(ms, function() return Fx.TimeoutError { timeoutMs = ms } end)
  end

  function Effect:timeoutFail(ms, onTimeout)
    local TIMEOUT = {}
    return self:map(function(a) return { a } end)
      :raceFirst(Fx.sleep(ms):as(TIMEOUT))
      :flatMap(function(r)
        if r == TIMEOUT then return Fx.fail(onTimeout()) end
        return succeed(r[1])
      end)
  end

  ---Succeed with nil (instead of failing) when the timeout hits.
  function Effect:timeoutOption(ms)
    return self:timeout(ms):catchTag('TimeoutError', function() return succeed(nil) end)
  end

  local function isArray(t)
    if #t > 0 then return true end
    return next(t) == nil
  end

  ---Run f on every item. opts.concurrency = number | "unbounded" (default 1).
  ---Succeeds with the results in order. The first failure interrupts the rest.
  function Fx.forEach(items, f, opts)
    local n = #items
    local concurrency = opts and opts.concurrency or 1
    if concurrency == 'unbounded' then concurrency = n end
    local discard = opts and opts.discard
    if concurrency <= 1 or n <= 1 then
      local results = {}
      local function go(i)
        if i > n then return succeed(discard and nil or results) end
        return callf(f, items[i], i):flatMap(function(v)
          if not discard then results[i] = v end
          return go(i + 1)
        end)
      end
      return Fx.suspend(function() return go(1) end)
    end

    return mk(WITH_FIBER, function(parent)
      return mk(ASYNC, function(resume)
        local results, nextIdx, failed, live = {}, 0, false, 0
        local workers = {}
        local function worker()
          return Fx.suspend(function()
            nextIdx = nextIdx + 1
            local i = nextIdx
            if i > n or failed then return unit end
            return callf(f, items[i], i):flatMap(function(v)
              if not discard then results[i] = v end
              return worker()
            end)
          end)
        end
        local k = math.min(concurrency, n)
        for w = 1, k do workers[w] = Fiber.new(worker(), parent.context, parent) end
        live = k
        for w = 1, k do
          workers[w]:addObserver(function(exit)
            live = live - 1
            if failed then return end
            if exit._tag == 'Failure' then
              failed = true
              local others = {}
              for j = 1, k do if j ~= w then others[#others + 1] = workers[j] end end
              resume(Fx.interruptAll(others):zipRight(failCause(exit.cause)))
            elseif live == 0 then
              resume(succeed(discard and nil or results))
            end
          end)
        end
        for w = 1, k do workers[w]:start() end
        return function()
          for _, w in ipairs(workers) do w:interruptAsFork(parent.id) end
        end
      end)
    end)
  end

  ---Run a list or a record of effects. Succeeds with results of the same shape.
  function Fx.all(effects, opts)
    if isArray(effects) then
      return Fx.forEach(effects, function(e) return e end, opts)
    end
    local keys, list = {}, {}
    for k, e in pairs(effects) do
      keys[#keys + 1] = k
      list[#list + 1] = e
    end
    return Fx.forEach(list, function(e) return e end, opts):map(function(results)
      local out = {}
      for i, k in ipairs(keys) do out[k] = results[i] end
      return out
    end)
  end

  ---------------------------------------------------------------------------
  -- Running effects
  ---------------------------------------------------------------------------

  Fx._defaultContext = {}

  -- The most recent failures (error logs, unhandled fiber failures, defects
  -- in callbacks), for the devtools. seq lets a reader ask for newer ones only.
  local FAILURES = 50
  local failures, failureSeq = {}, 0

  function Fx._recordFailure(message, fields)
    failureSeq = failureSeq + 1
    failures[(failureSeq - 1) % FAILURES + 1] = {
      seq = failureSeq,
      time = Fx.trace and Fx.trace.nowMs() or 0,
      message = message,
      fields = fields,
    }
  end

  ---Recorded failures with seq > after, oldest first.
  function Fx._recentFailures(after)
    after = after or 0
    local out = {}
    for seq = math.max(after + 1, failureSeq - FAILURES + 1), failureSeq do
      out[#out + 1] = failures[(seq - 1) % FAILURES + 1]
    end
    return out
  end

  function Fx._reportDefect(where, err)
    Fx._recordFailure('error in ' .. tostring(where), { cause = tostring(err) })
    print(('^1[rivo_fx] error in %s: %s^7'):format(where, tostring(err)))
  end

  function Fx._reportUnhandled(fiber, cause)
    local fields = { fiber = fiber.id, cause = Cause.pretty(cause) }
    local span = Fx.trace and (Fx.trace.failedSpanOf(cause) or fiber.context[Fx.trace.CurrentSpan])
    if span then fields.traceId, fields.spanId = span.traceId, span.spanId end
    if Fx.log then
      Fx.log.error('Unhandled failure in fiber #' .. fiber.id, fields) -- also records it
    else
      Fx._recordFailure('Unhandled failure in fiber #' .. fiber.id, fields)
      print(('^1[rivo_fx] Unhandled failure in fiber #%d:\n%s^7'):format(fiber.id, fields.cause))
    end
  end

  ---Start eff on a new root fiber and return the fiber.
  ---opts.onExit(exit) is called when it finishes. Without onExit, failures are logged.
  ---@param eff Fx.Effect
  ---@param opts? { onExit?: fun(exit: Fx.Exit), context?: table }
  ---@return Fx.Fiber
  function Fx.runFork(eff, opts)
    local fiber = Fiber.new(eff, opts and opts.context or Fx._defaultContext, nil)
    rootFibers[fiber] = true
    if opts and opts.onExit then
      fiber:addObserver(opts.onExit)
    else
      fiber.reportUnhandled = true
    end
    return fiber:start()
  end

  ---Run eff and call cb(exit) when done.
  function Fx.runCallback(eff, cb, opts)
    return Fx.runFork(eff, { onExit = cb, context = opts and opts.context })
  end

  ---Run eff right now in the current context. Fails if eff needs to wait.
  ---@return Fx.Exit
  function Fx.runSyncExit(eff, opts)
    local fiber = Fiber.new(eff, opts and opts.context or Fx._defaultContext, nil)
    return fiber:run(true)
  end

  ---Run eff synchronously and return its value. Raises on failure: the error
  ---itself for expected failures, the defect otherwise.
  function Fx.runSync(eff, opts)
    local exit = Fx.runSyncExit(eff, opts)
    if exit._tag == 'Success' then return exit.value end
    Fx._raiseCause(exit.cause)
  end

  function Fx._raiseCause(cause)
    local e = Cause.failureOption(cause)
    if e ~= nil and #Cause.defects(cause) == 0 then error(e, 0) end
    local d = Cause.defects(cause)[1]
    if d ~= nil then
      local trace
      Cause.walk(cause, function(n) if n._tag == 'Die' and not trace then trace = n.trace end end)
      if type(d) == 'string' and trace then error(d .. '\n' .. trace, 0) end
      error(d, 0)
    end
    error({ _fxCause = cause, _tag = 'Interrupted' }, 0)
  end

  ---Run eff from plain code on a Citizen thread and block until it finishes.
  ---Returns the value; raises the error on failure (pcall-able). Level-0 entry point.
  ---@generic A
  ---@param eff Fx.Effect<A, any>
  ---@return A
  function Fx.runAwait(eff, opts)
    local fiber = Fiber.new(eff, opts and opts.context or Fx._defaultContext, nil)
    rootFibers[fiber] = true
    local exit = P.current.suspend(function(resolve)
      fiber:addObserver(resolve)
      fiber:start()
    end)
    if exit._tag == 'Success' then return exit.value end
    Fx._raiseCause(exit.cause)
  end

  ---Interrupt every root fiber. Used on resource stop.
  function Fx._interruptRoots()
    local list = {}
    for f in pairs(rootFibers) do list[#list + 1] = f end
    for _, f in ipairs(list) do f:interruptAsFork(0) end
    return #list
  end
end
