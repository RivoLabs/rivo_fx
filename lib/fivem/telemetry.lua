-- Lets the rivo_fx resource read this resource's metrics, spans, fibers and
-- failures: server/hub.lua for /rivo_fx/metrics, and the /fxdev devtools on
-- both sides. Loaded by init.lua in every resource that uses Rivo FX.
return function(Fx)
  local tel = {}
  Fx._telemetry = tel

  local side = Fx.isServer and 'server' or 'client'
  -- Changes when the resource restarts, so a reader's seq cursor from the
  -- last run is not applied to this one.
  local epoch = ('%08x'):format(math.random(0, 0x7fffffff))
  tel.epoch = epoch

  -- Values cross an export (msgpack) and reach a NUI page (JSON): keep plain
  -- data only, and keep it small.
  local function plain(v, depth)
    local t = type(v)
    if t == 'string' then return #v > 1000 and v:sub(1, 1000) .. '...' or v end
    if t == 'boolean' then return v end
    if t == 'number' then
      if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
      return v
    end
    if t == 'table' and depth < 3 then
      local out, n = {}, 0
      for k, x in pairs(v) do
        n = n + 1
        if n > 50 then break end
        out[type(k) == 'number' and k or tostring(k)] = plain(x, depth + 1)
      end
      return out
    end
    if v == nil then return nil end
    return tostring(v)
  end
  tel.plain = plain

  local function spanRecord(s)
    return {
      seq = s.seq, name = plain(s.name, 0), traceId = s.traceId, spanId = s.spanId,
      parentSpanId = s.parentSpanId, kind = s.kind, startTime = s.startTime, endTime = s.endTime,
      status = s.status, message = s.message, attributes = plain(s.attributes, 0),
      events = plain(s.events, 0), resource = s.resource, side = side,
    }
  end

  local function failureRecord(f)
    local fields, cause = {}, nil
    for k, v in pairs(f.fields or {}) do
      if k == 'cause' then cause = plain(tostring(v), 0) else fields[tostring(k)] = v end
    end
    if cause and #cause > 4000 then cause = cause:sub(1, 4000) .. '...' end
    return {
      seq = f.seq, time = f.time, message = plain(f.message, 0), cause = cause,
      fiber = math.type(fields.fiber) == 'integer' and fields.fiber or nil,
      traceId = type(fields.traceId) == 'string' and fields.traceId:sub(1, 32) or nil,
      spanId = type(fields.spanId) == 'string' and fields.spanId:sub(1, 16) or nil,
      fields = plain(fields, 1), resource = Fx.resourceName, side = side,
    }
  end

  local function fiberRecord(f, now)
    local status = 'running' -- or about to: queued to run this tick
    if f.interruptRequested then status = 'interrupting' elseif f.parked then status = 'waiting' end
    local span = f.context[Fx.trace.CurrentSpan]
    local children = 0
    for c in pairs(f.children) do if not c.exit then children = children + 1 end end
    return {
      id = f.id, parent = f.parent and f.parent.id or nil, status = status,
      age = f.born and now - f.born or nil, children = children,
      span = span and plain(span.name, 0) or nil, traceId = span and span.traceId or nil,
    }
  end

  local function byIdDesc(a, b) return a.id > b.id end

  ---Live fibers, each parent before its children: { total, list }.
  function tel.fibers(limit)
    limit = limit or 200
    local now = Fx._platform.current.now()
    local list, total, stack = {}, 0, {}
    for f in pairs(Fx._rootFibers) do stack[#stack + 1] = f end
    table.sort(stack, byIdDesc)
    while #stack > 0 do
      local f = table.remove(stack)
      if not f.exit then
        total = total + 1
        if #list < limit then list[#list + 1] = fiberRecord(f, now) end
        local kids = {}
        for c in pairs(f.children) do kids[#kids + 1] = c end
        table.sort(kids, byIdDesc)
        for _, c in ipairs(kids) do stack[#stack + 1] = c end
      end
    end
    return { total = total, list = list }
  end

  local function since(opts)
    if type(opts) == 'table' and opts.epoch == epoch and math.type(opts.after) == 'integer' then return opts.after end
    return 0
  end

  ---what: 'summary' | 'metrics' | 'spans' | 'failures' | 'fibers'.
  ---opts for spans and failures: { epoch, after } returns only newer ones
  ---(when epoch is this run's); opts for fibers: { limit } (at most 500).
  function tel.read(what, opts)
    if what == 'metrics' then
      -- a gauge can hold NaN or inf, which JSON (the NUI page) cannot carry
      local snap = Fx.metrics.snapshot()
      for _, m in ipairs(snap) do
        for _, sr in ipairs(m.series) do
          if sr.value ~= nil then sr.value = plain(sr.value, 0) end
          if sr.sum ~= nil then sr.sum = plain(sr.sum, 0) end
        end
      end
      return snap
    end
    if what == 'spans' then
      local out = {}
      for i, s in ipairs(Fx.trace.recent(since(opts))) do out[i] = spanRecord(s) end
      return { epoch = epoch, items = out }
    end
    if what == 'failures' then
      local out = {}
      for i, f in ipairs(Fx._recentFailures(since(opts))) do out[i] = failureRecord(f) end
      return { epoch = epoch, items = out }
    end
    if what == 'fibers' then
      local limit = type(opts) == 'table' and math.type(opts.limit) == 'integer' and opts.limit or 200
      return tel.fibers(math.max(1, math.min(limit, 500)))
    end
    if what == 'summary' then
      local fibers = 0
      for _ in pairs(Fx._rootFibers) do fibers = fibers + 1 end
      local recent = Fx._recentFailures(0)
      local last = recent[#recent]
      local spans = Fx.trace.recent(0)
      local st = Fx._platform.current.stats and Fx._platform.current.stats()
      return {
        resource = Fx.resourceName, side = side, version = Fx.version,
        rootFibers = fibers, live = tel.fibers(0).total, timers = st and st.timers or 0,
        spans = #spans > 0 and spans[#spans].seq or 0, failures = last and last.seq or 0,
        lastFailure = last and last.time or nil, lastFailureMessage = last and plain(last.message, 0) or nil,
        tracing = Fx.trace.isEnabled(),
      }
    end
    return nil
  end

  if not (exports and AddEventHandler and TriggerEvent) then return tel end

  exports('__rivo_fx_telemetry', tel.read)

  local function hello() TriggerEvent('rivo_fx:telemetry:hello', Fx.resourceName) end
  AddEventHandler('rivo_fx:telemetry:who', hello)
  hello()
  return tel
end
