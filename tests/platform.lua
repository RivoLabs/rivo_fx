-- Virtual-time platform for running Rivo FX outside FiveM.
-- Threads are coroutines; time only moves when nothing is runnable.
local M = {}

function M.new()
  local self = { time = 0, queue = {}, timers = {}, seq = 0, errors = {} }

  local function enqueue(co, ...)
    self.queue[#self.queue + 1] = { co = co, args = table.pack(...) }
  end

  local function addTimer(ms, fn)
    self.seq = self.seq + 1
    local t = { at = self.time + math.max(ms or 0, 0), seq = self.seq, fn = fn }
    self.timers[#self.timers + 1] = t
    return t
  end

  local function step(co, args)
    local res = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
    if not res[1] then
      self.errors[#self.errors + 1] = debug.traceback(co, tostring(res[2]))
      return
    end
    if coroutine.status(co) == 'dead' then return end
    if res[2] == 'WAIT' then
      addTimer(res[3] or 0, function() enqueue(co) end)
    end
    -- 'SUSPEND': whoever resolves it enqueues the thread.
  end

  local p = { name = 'virtual' }

  function p.spawn(fn) enqueue(coroutine.create(fn)) end

  function p.suspend(register)
    local co = coroutine.running()
    local done, value, waiting = false, nil, false
    register(function(v)
      if done then return end
      done, value = true, v
      if waiting then enqueue(co, v) end
    end)
    if done then return value end
    waiting = true
    return coroutine.yield('SUSPEND')
  end

  function p.park(slot)
    slot.parkCo = coroutine.running()
    coroutine.yield('SUSPEND')
  end

  function p.unpark(slot)
    local co = slot.parkCo
    slot.parkCo = nil
    enqueue(co)
  end

  function p.setTimeout(ms, fn, arg)
    local t = addTimer(ms, function() fn(arg) end)
    return function() t.cancelled = true end
  end

  function p.yieldNow() coroutine.yield('WAIT', 0) end
  function p.now() return self.time end

  ---Stand-in for Citizen.Wait inside threads.
  function p.wait(ms) coroutine.yield('WAIT', ms) end

  ---Run until nothing is left or `limit` virtual ms pass.
  function p.run(limit)
    local deadline = limit and (self.time + limit) or math.huge
    while true do
      while #self.queue > 0 do
        local item = table.remove(self.queue, 1)
        step(item.co, item.args)
      end
      local live = {}
      for _, t in ipairs(self.timers) do if not t.cancelled then live[#live + 1] = t end end
      self.timers = live
      if #live == 0 then break end
      table.sort(live, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
      local nextAt = live[1].at
      if nextAt > deadline then self.time = deadline break end
      self.time = math.max(self.time, nextAt)
      local due = {}
      local rest = {}
      for _, t in ipairs(live) do
        if t.at <= self.time then due[#due + 1] = t else rest[#rest + 1] = t end
      end
      self.timers = rest
      for _, t in ipairs(due) do if not t.cancelled then t.fn() end end
    end
    if #self.errors > 0 then
      local errs = self.errors
      self.errors = {}
      error('thread crashed:\n' .. table.concat(errs, '\n'), 2)
    end
  end

  p.state = self
  return p
end

return M
