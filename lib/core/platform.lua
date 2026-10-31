-- Platform: the only place the core touches the host scheduler.
-- In FiveM, fibers run as coroutines on a per-resource runner with one timer
-- thread, and only borrow a Citizen thread while they yield to the host.
-- Tests swap in a virtual-time implementation (tests/platform.lua) through
-- Fx.setPlatform.
return function(Fx)
  local P = {}

  local co_yield = coroutine.yield

  ---The light userdata Citizen.Await yields to detach a thread. scheduler.lua
  ---hides it (Citizen.AwaitSentinel is cleared), so read it back from Await's
  ---upvalues. nil when that fails, and suspend falls back to promises.
  local function findAwaitSentinel()
    if not (debug and debug.getupvalue and Citizen and Citizen.Await) then return nil end
    for i = 1, 32 do
      local name, value = debug.getupvalue(Citizen.Await, i)
      if name == nil then break end
      if name == 'AwaitSentinel' and value ~= nil then return value end
    end
    return nil
  end

  local function citizen()
    local sentinel = findAwaitSentinel()

    ---Suspend the current thread until the callback passed to register is
    ---called. register may call it synchronously.
    local suspend
    if sentinel then
      -- Yielding the sentinel makes the runtime hand back a native reattach
      -- function; the second yield detaches the thread until it is called.
      -- Same protocol as Citizen.Await, without a promise per suspension.
      suspend = function(register)
        local done, value, reattach = false, nil, nil
        register(function(v)
          if done then return end
          done, value = true, v
          if reattach then
            local r = reattach
            reattach = nil
            r()
          end
        end)
        if done then return value end
        reattach = co_yield(sentinel)
        if not done then co_yield() end
        return value
      end
    else
      suspend = function(register)
        -- Box the value: promises treat any table with a .next field as a thenable.
        local p = promise.new()
        register(function(v) if p.state == 0 then p:resolve({ v }) end end)
        return Citizen.Await(p)[1]
      end
    end

    -- Fibers run as plain coroutines on a runner inside this resource, not as
    -- Citizen threads. Waking one is a coroutine.resume, not a round trip
    -- through the runtime's bookmark scheduler, which was most of the cost of
    -- every Fx.sleep. Fiber code that yields to the host (Citizen.Wait,
    -- Citizen.Await, a yielding native) is handed to a Citizen thread that
    -- forwards those yields; the fiber comes back to the runner the next time
    -- it parks.
    local co_create, co_resume, co_status, co_running =
      coroutine.create, coroutine.resume, coroutine.status, coroutine.running
    local table_pack, table_unpack = table.pack, table.unpack
    local traceback = debug.traceback
    -- Promotion must start the forwarding thread before the fiber's yield
    -- is acted on; a next-tick CreateThread would race Citizen.Await.
    local spawnNow = Citizen.CreateThreadNow
    if not spawnNow then error('rivo_fx needs Citizen.CreateThreadNow (FiveM Lua 5.4 runtime)', 0) end

    local PARK, YIELD = {}, {}
    local queue, qhead, qtail = {}, 1, 0 -- fibers ready to run now
    local nextTick = {}                  -- fibers to run on the next tick
    -- True while a fiber coroutine is being resumed somewhere up the stack.
    -- Wakes made then are only queued; whoever set it drains afterwards.
    local draining = false
    local ensurePump, promote, drain

    ---Report without ever raising: an error escaping a drain would leave the
    ---runner marked busy and stop every fiber in the resource.
    local function report(where, co, err)
      local ok, msg = pcall(function()
        return co and traceback(co, tostring(err)) or tostring(err)
      end)
      pcall(Fx._reportDefect, where, ok and msg or '(unprintable error)')
    end

    local function settle(co, ok, a, ...)
      if not ok then
        report('fiber', co, a)
      elseif co_status(co) == 'dead' or a == PARK then
        return
      elseif a == YIELD then
        nextTick[#nextTick + 1] = co
        ensurePump(GetGameTimer())
      else
        promote(co, table_pack(a, ...))
      end
    end

    local function drainLoop()
      while qhead <= qtail do
        local co = queue[qhead]
        queue[qhead] = nil
        qhead = qhead + 1
        settle(co, co_resume(co))
      end
    end

    -- A woken fiber runs once the code that woke it parks, yields or returns,
    -- never in the middle of it.
    drain = function()
      if draining then return end
      draining = true
      local ok, err = pcall(drainLoop)
      draining = false
      if qhead > qtail then
        qhead, qtail = 1, 0
      elseif not ok then
        ensurePump(GetGameTimer()) -- whatever is left runs next tick
      end
      if not ok then report('fiber runner', nil, err) end
    end

    ---Give a fiber that yielded to the host its own Citizen thread. The
    ---thread yields exactly the values the fiber yielded (FiveM reads the
    ---last one, so padding them would change a Wait) and resumes the fiber
    ---with the answer, until the fiber parks, yields a tick, or finishes.
    promote = function(co, vals)
      spawnNow(function()
        while true do
          local back = table_pack(co_yield(table_unpack(vals, 1, vals.n)))
          local was = draining
          draining = true
          local r = table_pack(co_resume(co, table_unpack(back, 1, back.n)))
          draining = was
          local hostYield = r[1] and co_status(co) ~= 'dead' and r[2] ~= PARK and r[2] ~= YIELD
          if hostYield then
            vals = table_pack(table_unpack(r, 2, r.n))
          else
            settle(co, table_unpack(r, 1, r.n))
          end
          if not was then drain() end
          if not hostYield then return end
        end
      end)
    end

    ---Park the running fiber until unpark(slot). The caller calls unpark at
    ---most once, and only after park has started.
    local function park(slot)
      slot.parkCo = co_running()
      co_yield(PARK)
    end

    local function unpark(slot)
      local co = slot.parkCo
      slot.parkCo = nil
      qtail = qtail + 1
      queue[qtail] = co
      drain()
    end

    ---Run fn as a new fiber coroutine from the next tick on, like CreateThread.
    local function spawn(fn)
      nextTick[#nextTick + 1] = co_create(fn)
      ensurePump(GetGameTimer())
    end

    -- Timers: a binary heap. Citizen.SetTimeout creates a whole thread per
    -- call, which made every Fx.sleep expensive.
    local heap, seq = {}, 0

    -- Entries are { due, seq, fn, arg, cancelled }; ordered by due, then seq.
    -- Comparisons are inlined: this runs for every Fx.sleep. Calling an entry
    -- cancels it, so it doubles as its own canceler without a closure.
    -- Cancelling drops fn and arg so a cancelled timer does not keep its
    -- fiber alive until it would have been due.
    local Entry = { __call = function(t) t[3], t[4], t[5] = nil, nil, true end }
    local function push(t)
      local n = #heap + 1
      local due, sq = t[1], t[2]
      while n > 1 do
        local parent = n // 2
        local p = heap[parent]
        local pd = p[1]
        if pd < due or (pd == due and p[2] < sq) then break end
        heap[n] = p
        n = parent
      end
      heap[n] = t
    end

    local function pop()
      local n = #heap
      local top, last = heap[1], heap[n]
      heap[n] = nil
      n = n - 1
      if n > 0 then
        local due, sq = last[1], last[2]
        local i = 1
        while true do
          local c = i * 2
          if c > n then break end
          local ce = heap[c]
          if c < n then
            local r = heap[c + 1]
            if r[1] < ce[1] or (r[1] == ce[1] and r[2] < ce[2]) then c, ce = c + 1, r end
          end
          if due < ce[1] or (due == ce[1] and sq < ce[2]) then break end
          heap[i] = ce
          i = c
        end
        heap[i] = last
      end
      return top
    end

    -- Pump threads fire due timers and start nextTick fibers. A pump sleeps
    -- until the earliest timer and exits when there is nothing left. A
    -- sleeping pump cannot be woken early, so work due sooner starts another
    -- pump; after each pass a pump only goes back to sleep if no other pump
    -- already covers its next wake, so at most a couple ever exist.
    local active = 0    -- pumps scheduled to start or in the middle of a pass
    local sleepers = {} -- sleeping pump -> game time it wakes
    local MAX_WAIT = 2147483647

    local function covered(due)
      if active > 0 then return true end -- that pass reschedules from the heap
      for _, at in pairs(sleepers) do
        if at <= due then return true end
      end
      return false
    end

    local function pass()
      -- Fibers started or yielded on an earlier tick go first: on a 20 Hz
      -- server a fork and its parent's Fx.sleep(50) come due in the same
      -- pass, and the child must not start after the parent has moved on.
      local n = #nextTick
      if n > 0 then
        local list = nextTick
        nextTick = {}
        for i = 1, n do
          qtail = qtail + 1
          queue[qtail] = list[i]
        end
      end
      -- Only timers that existed when this pass began: one made by a fiber
      -- woken here waits for the next tick, so Fx.sleep(0) in a loop gives
      -- the frame back instead of spinning inside it.
      local now, last = GetGameTimer(), seq
      while heap[1] and heap[1][1] <= now and heap[1][2] <= last do
        local t = pop()
        if not t[5] then
          local ok, err = pcall(t[3], t[4])
          if not ok then report('timer', nil, err) end
        end
      end
    end

    ---When the next pass is needed, or nil when there is nothing to do.
    local function nextDue()
      if #nextTick > 0 then return GetGameTimer() end
      while heap[1] and heap[1][5] do pop() end -- cancelled, never fires
      return heap[1] and heap[1][1]
    end

    local function pump()
      local me = {}
      while true do
        draining = true
        local ok, err = pcall(pass)
        draining = false
        if not ok then report('timer pump', nil, err) end
        drain()
        active = active - 1
        local due = nextDue()
        if due == nil or covered(due) then return end
        local wait = due - GetGameTimer()
        if not (wait > 0) then wait = 0 end -- also NaN
        if wait > MAX_WAIT then wait = MAX_WAIT end
        sleepers[me] = due
        Citizen.Wait(math.ceil(wait))
        sleepers[me] = nil
        active = active + 1
      end
    end

    ---Make sure some pump runs a pass by game time `due`.
    ensurePump = function(due)
      if covered(due) then return end
      active = active + 1
      Citizen.CreateThread(pump)
    end

    ---Call fn(arg) after ms. Returns a canceler (a callable table).
    local function setTimeout(ms, fn, arg)
      seq = seq + 1
      ms = tonumber(ms) or 0
      if not (ms > 0) then ms = 0 end -- also NaN
      local due = GetGameTimer() + ms
      local t = setmetatable({ due, seq, fn, arg, false }, Entry)
      push(t)
      ensurePump(due)
      return t
    end

    return {
      name = 'citizen',
      native = sentinel ~= nil,
      ---Run fn as a new fiber from the next tick on.
      spawn = spawn,
      suspend = suspend,
      park = park,
      unpark = unpark,
      setTimeout = setTimeout,
      ---Give the frame back to the game (cooperative yield in long sync loops).
      ---Only called from fiber code: the fiber continues on the next tick.
      yieldNow = function() co_yield(YIELD) end,
      now = function() return GetGameTimer() end,
      ---Runner state, for tests and diagnostics.
      stats = function()
        local n = 0
        for _ in pairs(sleepers) do n = n + 1 end
        return { active = active, sleepingPumps = n, timers = #heap, queued = qtail - qhead + 1 }
      end,
    }
  end

  P.current = (Citizen and Citizen.CreateThread) and citizen() or nil

  function Fx.setPlatform(p) P.current = p end
  function Fx.getPlatform() return P.current end

  Fx._platform = P
end
