-- Token-bucket rate limiter keyed by anything (usually the player id).
-- Spec: "<n>/s", "<n>/m" or "<n>/h": capacity n, refilled n per period.
return function(Fx)
  local RateLimiter = {}
  RateLimiter.__index = RateLimiter

  local PERIODS = { s = 1000, m = 60000, h = 3600000 }

  function RateLimiter.parse(spec)
    local n, unit = tostring(spec):match('^%s*(%d+)%s*/%s*([smh])%s*$')
    if not n then error(('invalid rate limit %q (use "10/s", "30/m" or "100/h")'):format(tostring(spec)), 3) end
    n = tonumber(n)
    if n < 1 then error('rate limit must allow at least 1', 3) end
    return n, PERIODS[unit]
  end

  ---@param spec string e.g. "10/s"
  function RateLimiter.new(spec)
    local capacity, period = RateLimiter.parse(spec)
    return setmetatable({ capacity = capacity, period = period, buckets = {} }, RateLimiter)
  end

  ---Take one token for key. Returns false when the bucket is empty.
  function RateLimiter:take(key)
    local now = Fx._platform.current.now()
    local b = self.buckets[key]
    if not b then
      b = { tokens = self.capacity, at = now }
      self.buckets[key] = b
    else
      local refill = (now - b.at) * self.capacity / self.period
      b.tokens = math.min(self.capacity, b.tokens + refill)
      b.at = now
    end
    if b.tokens >= 1 then
      b.tokens = b.tokens - 1
      return true
    end
    return false
  end

  function RateLimiter:forget(key) self.buckets[key] = nil end

  -- Drop buckets for players who leave.
  local all = setmetatable({}, { __mode = 'k' })
  local origNew = RateLimiter.new
  function RateLimiter.new(spec)
    local l = origNew(spec)
    all[l] = true
    return l
  end
  if Fx.isServer and AddEventHandler then
    AddEventHandler('playerDropped', function()
      local src = tonumber(source)
      for l in pairs(all) do l:forget(src) end
    end)
  end

  return RateLimiter
end
