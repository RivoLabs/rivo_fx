-- Ref, Deferred, Semaphore, Queue, PubSub.
return function(Fx)
  local succeed, sync, async = Fx.succeed, Fx.sync, Fx.async

  local function removeValue(list, v)
    for i = #list, 1, -1 do
      if list[i] == v then table.remove(list, i) return end
    end
  end

  ---------------------------------------------------------------------------
  -- Ref: a mutable cell that fibers can share.
  ---------------------------------------------------------------------------
  local Ref = {}
  Ref.__index = Ref
  Fx.Ref = Ref

  function Ref.unsafeMake(v) return setmetatable({ value = v }, Ref) end
  function Ref.make(v) return sync(function() return Ref.unsafeMake(v) end) end
  function Ref:get() return sync(function() return self.value end) end
  function Ref:set(v) return sync(function() self.value = v end) end
  function Ref:update(f) return sync(function() self.value = f(self.value) end) end
  function Ref:updateAndGet(f) return sync(function() self.value = f(self.value) return self.value end) end
  function Ref:getAndSet(v) return sync(function() local old = self.value self.value = v return old end) end
  ---f(old) returns (result, new)
  function Ref:modify(f)
    return sync(function()
      local r, new = f(self.value)
      self.value = new
      return r
    end)
  end

  ---------------------------------------------------------------------------
  -- Deferred: a value set once, awaited by any number of fibers.
  ---------------------------------------------------------------------------
  local Deferred = {}
  Deferred.__index = Deferred
  Fx.Deferred = Deferred

  function Deferred.unsafeMake() return setmetatable({ exit = nil, waiters = {} }, Deferred) end
  function Deferred.make() return sync(Deferred.unsafeMake) end

  function Deferred:unsafeDone(exit)
    if self.exit then return false end
    self.exit = exit
    local ws = self.waiters
    self.waiters = {}
    for i = 1, #ws do ws[i](exit) end
    return true
  end

  function Deferred:done(exit) return sync(function() return self:unsafeDone(exit) end) end
  function Deferred:succeed(v) return self:done(Fx.Exit.succeed(v)) end
  function Deferred:fail(e) return self:done(Fx.Exit.failCause(Fx.Cause.fail(e))) end
  function Deferred:isDone() return self.exit ~= nil end

  function Deferred:await()
    return async(function(resume)
      if self.exit then return resume(Fx.fromExit(self.exit)) end
      local function w(exit) resume(Fx.fromExit(exit)) end
      self.waiters[#self.waiters + 1] = w
      return function() removeValue(self.waiters, w) end
    end)
  end

  ---------------------------------------------------------------------------
  -- Semaphore: limit how many fibers run a section at once.
  ---------------------------------------------------------------------------
  local Semaphore = {}
  Semaphore.__index = Semaphore
  Fx.Semaphore = Semaphore

  function Semaphore.unsafeMake(permits)
    return setmetatable({ permits = permits, waiters = {} }, Semaphore)
  end
  function Semaphore.make(permits) return sync(function() return Semaphore.unsafeMake(permits) end) end

  function Semaphore:take(n)
    n = n or 1
    return async(function(resume)
      if #self.waiters == 0 and self.permits >= n then
        self.permits = self.permits - n
        return resume(Fx.unit)
      end
      local w = { n = n, resume = resume }
      self.waiters[#self.waiters + 1] = w
      return function() removeValue(self.waiters, w) end
    end)
  end

  function Semaphore:unsafeRelease(n)
    self.permits = self.permits + (n or 1)
    while #self.waiters > 0 and self.permits >= self.waiters[1].n do
      local w = table.remove(self.waiters, 1)
      self.permits = self.permits - w.n
      w.resume(Fx.unit)
    end
  end

  function Semaphore:release(n) return sync(function() self:unsafeRelease(n) end) end

  ---Run eff holding n permits; they are released however eff ends.
  function Semaphore:withPermits(n, eff)
    local sem = self
    return Fx.acquireUseRelease(sem:take(n), function() return eff end,
      function() return sem:release(n) end)
  end

  function Semaphore:withPermit(eff) return self:withPermits(1, eff) end

  ---------------------------------------------------------------------------
  -- Queue: FIFO between fibers. take() waits when empty; offer() on a full
  -- bounded queue waits for room.
  ---------------------------------------------------------------------------
  local Queue = {}
  Queue.__index = Queue
  Fx.Queue = Queue

  local function newQueue(capacity, strategy)
    return setmetatable({
      items = {}, head = 1, tail = 0,
      capacity = capacity, strategy = strategy,
      takers = {}, putters = {},
    }, Queue)
  end

  function Queue.unbounded() return sync(function() return newQueue(math.huge, 'suspend') end) end
  function Queue.bounded(n) return sync(function() return newQueue(n, 'suspend') end) end
  ---Bounded queue that drops new items when full.
  function Queue.dropping(n) return sync(function() return newQueue(n, 'dropping') end) end
  ---Bounded queue that drops the oldest item when full.
  function Queue.sliding(n) return sync(function() return newQueue(n, 'sliding') end) end
  Queue.unsafeUnbounded = function() return newQueue(math.huge, 'suspend') end
  ---capacity (default unbounded), strategy 'suspend' | 'dropping' | 'sliding'.
  function Queue.unsafeMake(capacity, strategy) return newQueue(capacity or math.huge, strategy or 'suspend') end

  function Queue:unsafeSize() return self.tail - self.head + 1 end
  function Queue:size() return sync(function() return self:unsafeSize() end) end

  local function pop(q)
    local v = q.items[q.head]
    q.items[q.head] = nil
    q.head = q.head + 1
    return v
  end

  local function push(q, v)
    q.tail = q.tail + 1
    q.items[q.tail] = v
  end

  local function drainPutters(q)
    while #q.putters > 0 and q:unsafeSize() < q.capacity do
      local p = table.remove(q.putters, 1)
      push(q, p.value)
      p.resume(succeed(true))
    end
  end

  ---Non-blocking offer. Returns false when the item was dropped or must wait.
  function Queue:unsafeOffer(v)
    if #self.takers > 0 then
      local t = table.remove(self.takers, 1)
      t(succeed(v))
      return true
    end
    if self:unsafeSize() < self.capacity then
      push(self, v)
      return true
    end
    if self.strategy == 'sliding' then
      pop(self)
      push(self, v)
      return true
    end
    return false
  end

  function Queue:offer(v)
    return async(function(resume)
      if self:unsafeOffer(v) then return resume(succeed(true)) end
      if self.strategy == 'dropping' then return resume(succeed(false)) end
      local p = { value = v, resume = resume }
      self.putters[#self.putters + 1] = p
      return function() removeValue(self.putters, p) end
    end)
  end

  function Queue:take()
    return async(function(resume)
      if self:unsafeSize() > 0 then
        local v = pop(self)
        drainPutters(self)
        return resume(succeed(v))
      end
      self.takers[#self.takers + 1] = resume
      return function() removeValue(self.takers, resume) end
    end)
  end

  ---Take an item now if there is one (else nil), outside any effect.
  function Queue:unsafePoll()
    if self:unsafeSize() == 0 then return nil end
    local v = pop(self)
    drainPutters(self)
    return v
  end

  ---Take an item if there is one, else nil.
  function Queue:poll()
    return sync(function()
      if self:unsafeSize() == 0 then return nil end
      local v = pop(self)
      drainPutters(self)
      return v
    end)
  end

  ---Take everything currently queued.
  function Queue:takeAll()
    return sync(function()
      local out = {}
      while self:unsafeSize() > 0 do out[#out + 1] = pop(self) end
      drainPutters(self)
      return out
    end)
  end

  ---------------------------------------------------------------------------
  -- PubSub: every subscriber gets every message published after it subscribed.
  ---------------------------------------------------------------------------
  local PubSub = {}
  PubSub.__index = PubSub
  Fx.PubSub = PubSub

  function PubSub.unsafeMake() return setmetatable({ subs = {}, listeners = {} }, PubSub) end
  function PubSub.make() return sync(PubSub.unsafeMake) end

  function PubSub:unsafePublish(v)
    for q in pairs(self.subs) do q:unsafeOffer(v) end
    for i = 1, #self.listeners do
      local ok, err = pcall(self.listeners[i], v)
      if not ok then Fx._reportDefect('PubSub listener', err) end
    end
  end

  function PubSub:publish(v) return sync(function() self:unsafePublish(v) end) end

  ---Scoped subscription: a Queue that receives messages until the scope closes.
  ---opts.buffer caps the queue (unbounded by default); when it is full the
  ---oldest message is dropped (opts.strategy = 'sliding', the default) or the
  ---newest ('dropping'). Publishing never waits.
  function PubSub:subscribe(opts)
    local ps = self
    local capacity = opts and opts.buffer or math.huge
    local strategy = opts and opts.strategy or 'sliding'
    return Fx.acquireRelease(sync(function()
      local q = newQueue(capacity, strategy)
      ps.subs[q] = true
      return q
    end), function(q) return sync(function() ps.subs[q] = nil end) end)
  end

  ---Plain callback listener. Returns an unsubscribe function.
  function PubSub:on(fn)
    local ls = self.listeners
    ls[#ls + 1] = fn
    return function() removeValue(ls, fn) end
  end
end
