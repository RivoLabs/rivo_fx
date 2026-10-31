-- Scope, Layer and Runtime.
return function(Fx)
  local Effect, Cause, Exit = Fx.Effect, Fx.Cause, Fx.Exit
  local succeed, sync, unit = Fx.succeed, Fx.sync, Fx.unit

  ---------------------------------------------------------------------------
  -- Scope
  ---------------------------------------------------------------------------

  ---The Scope service. Finalizers added to a scope run, last added first,
  ---when it closes. Every open scope also closes when the resource stops.
  local ScopeTag = Fx.Tag('Scope')
  Fx.Scope = ScopeTag

  local ScopeObj = {}
  ScopeObj.__index = ScopeObj

  -- Open scopes in creation order, so resource stop closes children first.
  local openScopes, scopeSeq = {}, 0

  function ScopeTag.unsafeMake()
    scopeSeq = scopeSeq + 1
    local s = setmetatable({ id = scopeSeq, finalizers = {}, closed = false }, ScopeObj)
    openScopes[s] = scopeSeq
    return s
  end

  function ScopeTag.make() return sync(ScopeTag.unsafeMake) end

  ---Returns a function that removes the finalizer again.
  function ScopeObj:unsafeAddFinalizer(fin)
    if self.closed then
      Fx.runFork(Fx.suspend(function() return fin(self.exit or Exit.unit) end))
      return function() end
    end
    local list = self.finalizers
    list[#list + 1] = fin
    return function()
      local current = self.finalizers
      for i = #current, 1, -1 do
        if current[i] == fin then table.remove(current, i) return end
      end
    end
  end

  ---Interrupt fiber when this scope closes (until the fiber ends by itself).
  function ScopeObj:unsafeAttachFiber(fiber)
    local remove = self:unsafeAddFinalizer(function()
      return sync(function() fiber:interruptAsFork(0) end)
    end)
    fiber:addObserver(function() remove() end)
  end

  ---fin(exit) must return an effect.
  function ScopeObj:addFinalizer(fin)
    return sync(function() self:unsafeAddFinalizer(fin) end)
  end

  local function takeFinalizers(s, exit)
    if s.closed then return nil end
    s.closed = true
    s.exit = exit
    openScopes[s] = nil
    local fins = s.finalizers
    s.finalizers = {}
    return fins
  end

  ---Close the scope: run finalizers in reverse order, uninterruptibly.
  ---A failing finalizer is logged and does not stop the others.
  function ScopeObj:close(exit)
    local s = self
    return Fx.suspend(function()
      local fins = takeFinalizers(s, exit or Exit.unit)
      if not fins then return unit end
      local list = {}
      for i = #fins, 1, -1 do list[#list + 1] = fins[i] end
      return Fx.forEach(list, function(fin)
        return Fx.suspend(function() return fin(exit or Exit.unit) end):catchAllCause(function(c)
          Fx._reportDefect('scope finalizer', Cause.pretty(c))
          return unit
        end)
      end, { discard = true })
    end):uninterruptible()
  end

  ---Close right now without suspending. Finalizers that need to wait are
  ---reported and skipped. Used on resource stop, when no later tick exists.
  function ScopeObj:closeSync(exit)
    local fins = takeFinalizers(self, exit or Exit.unit)
    if not fins then return end
    for i = #fins, 1, -1 do
      local res = Fx.runSyncExit(Fx.suspend(function() return fins[i](exit or Exit.unit) end))
      if res._tag == 'Failure' then
        Fx._reportDefect('scope finalizer on stop', Cause.pretty(res.cause))
      end
    end
  end

  ---A child scope that closes when this one closes (or earlier, on its own).
  function ScopeObj:fork()
    local child = ScopeTag.unsafeMake()
    self:unsafeAddFinalizer(function(exit) return child:close(exit) end)
    return child
  end

  ---Run eff with this scope as its Scope service.
  function ScopeObj:extend(eff) return eff:provideService(ScopeTag, self) end

  ---Close every open scope, newest first. Returns how many were closed.
  function Fx._closeAllScopes(exit)
    local list = {}
    for s, seq in pairs(openScopes) do list[#list + 1] = { s, seq } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    for _, e in ipairs(list) do e[1]:closeSync(exit) end
    return #list
  end

  ---Run eff in a fresh scope that closes when eff ends.
  function Fx.scoped(eff)
    return Fx.acquireUseRelease(ScopeTag.make(),
      function(s) return s:extend(eff) end,
      function(s, exit) return s:close(exit) end)
  end

  ---Add a finalizer to the current Scope.
  function Fx.addFinalizer(fin)
    return ScopeTag:flatMap(function(s) return s:addFinalizer(fin) end)
  end

  ---Acquire a resource and release it when the current Scope closes.
  ---release(a, exit) must return an effect.
  ---@generic A
  ---@param acquire Fx.Effect<A, any>
  ---@param release fun(a: A, exit: Fx.Exit): Fx.Effect
  ---@return Fx.Effect<A, any>
  function Fx.acquireRelease(acquire, release)
    return ScopeTag:flatMap(function(s)
      return acquire:tap(function(a)
        return s:addFinalizer(function(exit) return release(a, exit) end)
      end)
    end):uninterruptible()
  end

  ---Fork self as a daemon fiber that is interrupted when the current Scope closes.
  function Effect:forkScoped()
    local eff = self
    return ScopeTag:flatMap(function(s)
      return eff:forkDaemon():tap(function(fiber)
        return sync(function() s:unsafeAttachFiber(fiber) end)
      end)
    end):uninterruptible()
  end

  ---------------------------------------------------------------------------
  -- Layer
  ---------------------------------------------------------------------------

  ---A recipe for building services. Layers are built once per build (memoised
  ---by identity), in the scope of whoever provides them.
  local Layer = {}
  Layer.__index = Layer
  Fx.Layer = Layer

  local function layer(build) return setmetatable({ _build = build }, Layer) end

  local function buildMemo(l, memo, scope)
    local cached = memo[l]
    if cached then return succeed(cached) end
    return l._build(memo, scope):tap(function(ctx) memo[l] = ctx end)
  end

  ---@param tag Fx.Tag
  ---@param service any
  function Layer.succeed(tag, service)
    return layer(function() return succeed({ [tag] = service }) end)
  end

  function Layer.sync(tag, fn)
    return layer(function() return sync(fn):map(function(s) return { [tag] = s } end) end)
  end

  ---Build the service with an effect (which may use other services).
  function Layer.effect(tag, eff)
    return layer(function() return eff:map(function(s) return { [tag] = s } end) end)
  end

  ---Like effect, but eff can acquire resources (Fx.acquireRelease); they are
  ---released when the layer's scope closes.
  function Layer.scoped(tag, eff)
    return layer(function(_, scope)
      return scope:extend(eff):map(function(s) return { [tag] = s } end)
    end)
  end

  ---Run eff when the layer builds (and in its scope); provides no service.
  function Layer.effectDiscard(eff)
    return layer(function(_, scope) return scope:extend(eff):as({}) end)
  end

  Layer.empty = layer(function() return succeed({}) end)

  ---Combine layers; the result provides every service they provide.
  function Layer.merge(...)
    local layers = { ... }
    return layer(function(memo, scope)
      return Fx.forEach(layers, function(l) return buildMemo(l, memo, scope) end):map(function(ctxs)
        local out = {}
        for _, c in ipairs(ctxs) do for k, v in pairs(c) do out[k] = v end end
        return out
      end)
    end)
  end

  ---Feed dep's services into self. The result provides only self's services.
  function Layer:provide(dep)
    local this = self
    return layer(function(memo, scope)
      return buildMemo(dep, memo, scope):flatMap(function(depCtx)
        return buildMemo(this, memo, scope):provideContext(depCtx)
      end)
    end)
  end

  ---Feed dep's services into self and keep both.
  function Layer:provideMerge(dep)
    local this = self
    return layer(function(memo, scope)
      return buildMemo(dep, memo, scope):flatMap(function(depCtx)
        return buildMemo(this, memo, scope):provideContext(depCtx):map(function(ctx)
          return Fx.Context.merge(depCtx, ctx)
        end)
      end)
    end)
  end

  ---Build into the given scope. Succeeds with the context (tag -> service).
  function Layer:build(scope)
    return buildMemo(self, {}, scope)
  end

  ---Provide a Layer (built for this effect only) or a context table.
  function Effect:provide(what)
    local eff = self
    if getmetatable(what) ~= Layer then return eff:provideContext(what) end
    return Fx.acquireUseRelease(ScopeTag.make(), function(scope)
      return what:build(scope):flatMap(function(ctx) return eff:provideContext(ctx) end)
    end, function(scope, exit) return scope:close(exit) end)
  end

  ---------------------------------------------------------------------------
  -- Runtime: a layer built once and shared by many runs (event handlers, RPCs).
  ---------------------------------------------------------------------------

  local Runtime = {}
  Runtime.__index = Runtime
  Fx.Runtime = Runtime

  ---The layer builds on first use. Its scope closes on resource stop or dispose().
  ---@param l Fx.Layer
  ---@return Fx.Runtime
  function Runtime.make(l)
    return setmetatable({ layer = l, scope = ScopeTag.unsafeMake(), ready = nil }, Runtime)
  end

  ---Effect that succeeds with the built context.
  function Runtime:context()
    local rt = self
    return Fx.suspend(function()
      if not rt.ready then
        rt.ready = Fx.Deferred.unsafeMake()
        Fx.runFork(rt.layer:build(rt.scope), {
          onExit = function(exit)
            if exit._tag == 'Failure' then
              Fx._reportUnhandled({ id = 0 }, exit.cause)
            end
            rt.ready:unsafeDone(exit)
          end,
        })
      end
      return rt.ready:await()
    end)
  end

  ---eff with this runtime's services provided.
  function Runtime:wrap(eff)
    return self:context():flatMap(function(ctx) return eff:provideContext(ctx) end)
  end

  function Runtime:runFork(eff, opts) return Fx.runFork(self:wrap(eff), opts) end
  function Runtime:runCallback(eff, cb) return Fx.runCallback(self:wrap(eff), cb) end
  function Runtime:runAwait(eff) return Fx.runAwait(self:wrap(eff)) end

  ---Release everything the layer acquired.
  function Runtime:dispose()
    return self.scope:close(Exit.unit)
  end

  Fx._runtime = nil

  ---Make rt the default runtime for Fx.net / Fx.rpc handlers in this resource.
  function Fx.setRuntime(rt) Fx._runtime = rt end
end
