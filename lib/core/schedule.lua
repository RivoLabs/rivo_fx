-- Schedule: when and how often to retry or repeat.
-- A schedule is { initial = state, step = fun(state, input, now): (continue, delayMs, nextState) }.
return function(Fx)
  local P = Fx._platform
  local Effect = Fx.Effect

  local Schedule = {}
  Schedule.__index = Schedule
  Fx.Schedule = Schedule

  local function make(initial, step)
    return setmetatable({ initial = initial, step = step }, Schedule)
  end
  Schedule.make = make

  ---Every ms, forever.
  function Schedule.spaced(ms)
    return make(nil, function(s) return true, ms, s end)
  end
  Schedule.fixed = Schedule.spaced

  ---No delay, forever.
  Schedule.forever = make(nil, function(s) return true, 0, s end)

  ---Up to n recurrences with no delay.
  function Schedule.recurs(n)
    return make(0, function(count) return count < n, 0, count + 1 end)
  end
  Schedule.once = Schedule.recurs(1)

  ---base, base*factor, base*factor^2, ...
  function Schedule.exponential(base, factor)
    factor = factor or 2
    return make(0, function(n) return true, math.floor(base * factor ^ n), n + 1 end)
  end

  ---base, base, 2*base, 3*base, 5*base, ...
  function Schedule.fibonacci(base)
    return make({ base, base }, function(s) return true, s[1], { s[2], s[1] + s[2] } end)
  end

  ---Both must continue; the longer delay wins.
  function Schedule:intersect(other)
    local a, b = self, other
    return make({ a.initial, b.initial }, function(s, input, now)
      local c1, d1, s1 = a.step(s[1], input, now)
      local c2, d2, s2 = b.step(s[2], input, now)
      return c1 and c2, math.max(d1, d2), { s1, s2 }
    end)
  end

  ---Either may continue; the shorter delay wins.
  function Schedule:union(other)
    local a, b = self, other
    return make({ a.initial, b.initial }, function(s, input, now)
      local c1, d1, s1 = a.step(s[1], input, now)
      local c2, d2, s2 = b.step(s[2], input, now)
      local d
      if c1 and c2 then d = math.min(d1, d2) elseif c1 then d = d1 else d = d2 end
      return c1 or c2, d, { s1, s2 }
    end)
  end

  ---At most n recurrences.
  function Schedule:take(n) return self:intersect(Schedule.recurs(n)) end

  ---Randomise each delay between min and max times itself (default 0.8 to 1.2).
  function Schedule:jittered(min, max)
    min, max = min or 0.8, max or 1.2
    local inner = self
    return make(inner.initial, function(s, input, now)
      local c, d, s2 = inner.step(s, input, now)
      return c, math.floor(d * (min + math.random() * (max - min))), s2
    end)
  end

  ---Never wait longer than ms between recurrences.
  function Schedule:maxDelay(ms)
    local inner = self
    return make(inner.initial, function(s, input, now)
      local c, d, s2 = inner.step(s, input, now)
      return c, math.min(d, ms), s2
    end)
  end

  ---Stop once ms have passed since the first step.
  function Schedule:upTo(ms)
    local inner = self
    return make({ start = nil, s = inner.initial }, function(st, input, now)
      local start = st.start or now
      local c, d, s2 = inner.step(st.s, input, now)
      return c and (now + d - start) <= ms, d, { start = start, s = s2 }
    end)
  end

  ---Continue only while pred(input) is true (input is the error for retry, the value for repeat).
  function Schedule:whileInput(pred)
    local inner = self
    return make(inner.initial, function(s, input, now)
      local c, d, s2 = inner.step(s, input, now)
      return c and pred(input), d, s2
    end)
  end

  local function toSchedule(policy)
    if getmetatable(policy) == Schedule then return policy end
    if type(policy) == 'number' then return Schedule.recurs(policy) end
    local s = policy.schedule or Schedule.forever
    if policy.times then s = s:take(policy.times) end
    if policy['while'] then s = s:whileInput(policy['while']) end
    if policy['until'] then
      local u = policy['until']
      s = s:whileInput(function(i) return not u(i) end)
    end
    return s
  end

  ---Retry on expected failures following the policy:
  ---  eff:retry(3)
  ---  eff:retry(Fx.Schedule.exponential(100):take(5))
  ---  eff:retry { times = 3, schedule = Fx.Schedule.spaced(500), while = function(e) return e._tag == 'Busy' end }
  function Effect:retry(policy)
    local schedule = toSchedule(policy)
    local eff = self
    local function attempt(state)
      return eff:catchAll(function(e)
        local cont, delay, nextState = schedule.step(state, e, P.current.now())
        if not cont then return Fx.fail(e) end
        local again = Fx.suspend(function() return attempt(nextState) end)
        if delay > 0 then return Fx.sleep(delay):zipRight(again) end
        return again
      end)
    end
    return Fx.suspend(function() return attempt(schedule.initial) end)
  end

  ---Run, then keep running after each success as the schedule allows.
  ---Succeeds with the last value. (`repeat` is a Lua keyword, hence the name.)
  function Effect:repeatWith(schedule)
    schedule = toSchedule(schedule)
    local eff = self
    local function loop(state)
      return eff:flatMap(function(a)
        local cont, delay, nextState = schedule.step(state, a, P.current.now())
        if not cont then return Fx.succeed(a) end
        local again = Fx.suspend(function() return loop(nextState) end)
        if delay > 0 then return Fx.sleep(delay):zipRight(again) end
        return again
      end)
    end
    return Fx.suspend(function() return loop(schedule.initial) end)
  end
  Effect['repeat'] = Effect.repeatWith

  ---Run n + 1 times in total.
  function Effect:repeatN(n) return self:repeatWith(Schedule.recurs(n)) end
end
