-- Metrics: counters, gauges and histograms, kept per resource.
--
--   local Deposits = Fx.metrics.counter('bank_deposits_total', { help = 'Deposits made' })
--   Deposits:inc(1, { account = 'main' })
--   local Latency = Fx.metrics.histogram('bank_deposit_ms', { buckets = { 5, 25, 100, 500 } })
--   Bank.deposit(src, amount):trackDuration(Latency)
--
-- Fx.metrics.snapshot() returns every series; Fx.metrics.prometheus() renders
-- them in the Prometheus text format. On the server, the rivo_fx resource
-- serves every resource's metrics at /rivo_fx/metrics (see server/hub.lua).
return function(Fx)
  local P = Fx._platform
  local Effect = Fx.Effect

  local metrics = {}
  Fx.metrics = metrics

  local NAME = '^[%a_:][%w_:]*$'
  local LABEL = '^[%a_][%w_]*$'
  -- A label set an attacker controls (a player id, a payload field) must not
  -- grow memory without bound.
  local MAX_SERIES = 1000

  local registry, order = {}, {}

  local function labelKey(labels)
    if not labels or next(labels) == nil then return '' end
    local keys = {}
    for k in pairs(labels) do keys[#keys + 1] = k end
    table.sort(keys)
    -- length-prefixed, so no value can imitate another label set
    local parts = {}
    for i, k in ipairs(keys) do
      local v = tostring(labels[k])
      parts[i] = #k .. ':' .. k .. #v .. ':' .. v
    end
    return table.concat(parts)
  end

  local function copyLabels(labels)
    local out = {}
    if labels then
      for k, v in pairs(labels) do
        assert(type(k) == 'string' and k:match(LABEL), ('metrics: invalid label name %q'):format(tostring(k)))
        out[k] = tostring(v)
      end
    end
    return out
  end

  local Metric = {}
  Metric.__index = Metric

  -- The series for a label set, created on first use (nil when full).
  local function series(m, labels, init)
    local key = labelKey(labels)
    local s = m.series[key]
    if s then return s end
    if m.count >= MAX_SERIES then
      if not m.warned then
        m.warned = true
        if Fx.log then
          Fx.log.warn(('metric %s has %d label sets; new ones are dropped'):format(m.name, MAX_SERIES))
        end
      end
      return nil
    end
    s = init(copyLabels(labels))
    m.series[key] = s
    m.count = m.count + 1
    return s
  end

  local function newScalar(labels) return { labels = labels, value = 0 } end

  local function define(kind, name, opts)
    assert(type(name) == 'string' and name:match(NAME), ('Fx.metrics.%s: invalid name %q'):format(kind, tostring(name)))
    local existing = registry[name]
    if existing then
      assert(existing.kind == kind, ('Fx.metrics.%s(%q): already defined as a %s'):format(kind, name, existing.kind))
      return existing
    end
    local m = setmetatable({
      kind = kind, name = name, help = opts and opts.help or '',
      series = {}, count = 0, collect = opts and opts.collect,
    }, Metric)
    registry[name] = m
    order[#order + 1] = m
    return m
  end

  ---A value that only goes up.
  ---@return Fx.Counter
  function metrics.counter(name, opts) return define('counter', name, opts) end

  ---A value that goes up and down. opts.collect = fun(): number | { {labels, value}, ... }
  ---computes it when read instead.
  ---@return Fx.Gauge
  function metrics.gauge(name, opts) return define('gauge', name, opts) end

  local DEFAULT_BUCKETS = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }

  ---Counts of observations per bucket (upper bounds, ascending), plus sum and count.
  ---@return Fx.Histogram
  function metrics.histogram(name, opts)
    local m = define('histogram', name, opts)
    if not m.buckets then
      local b = opts and opts.buckets or DEFAULT_BUCKETS
      for i = 2, #b do assert(b[i] > b[i - 1], ('Fx.metrics.histogram(%q): buckets must ascend'):format(name)) end
      m.buckets = b
    end
    return m
  end

  ---Counter: add n (default 1, never negative).
  function Metric:inc(n, labels)
    n = n or 1
    if n < 0 then error(('metric %s: a counter cannot go down'):format(self.name), 2) end
    local s = series(self, labels, newScalar)
    if s then s.value = s.value + n end
  end

  ---Gauge: set the value.
  function Metric:set(v, labels)
    if type(v) ~= 'number' then error(('metric %s: value must be a number'):format(self.name), 2) end
    local s = series(self, labels, newScalar)
    if s then s.value = v end
  end

  ---Gauge: add n (may be negative).
  function Metric:add(n, labels)
    local s = series(self, labels, newScalar)
    if s then s.value = s.value + n end
  end

  ---Histogram: record one observation.
  function Metric:observe(v, labels)
    local buckets = self.buckets
    local s = series(self, labels, function(l)
      local counts = {}
      for i = 1, #buckets + 1 do counts[i] = 0 end
      return { labels = l, counts = counts, sum = 0, count = 0 }
    end)
    if not s then return end
    local i = 1
    while buckets[i] and v > buckets[i] do i = i + 1 end
    s.counts[i] = s.counts[i] + 1
    s.sum = s.sum + v
    s.count = s.count + 1
  end

  ---Counter/gauge: the value for a label set (0 when never set).
  function Metric:value(labels)
    local s = self.series[labelKey(labels)]
    return s and s.value or 0
  end

  ---Effect version of inc/set/observe for use inside pipelines.
  function Metric:update(v, labels)
    local m = self
    return Fx.sync(function()
      if m.kind == 'counter' then m:inc(v, labels)
      elseif m.kind == 'gauge' then m:set(v, labels)
      else m:observe(v, labels) end
    end)
  end

  -- Effects -------------------------------------------------------------------

  ---Observe how long self takes (ms, any outcome) in a histogram.
  function Effect:trackDuration(histogram, labels)
    local eff = self
    return Fx.suspend(function()
      local start = P.current.now()
      return Fx._onExitSync(eff, function() histogram:observe(P.current.now() - start, labels) end)
    end)
  end

  ---Count failures of self (not interruptions) in a counter, labelled with
  ---the error tag: `error` = the _tag of an error declared in this resource
  ---with Fx.TaggedError, "error" for any other tagged error (one rebuilt from
  ---another side, which a client could make up), "defect" or "unknown".
  function Effect:trackErrors(counter, labels)
    return Fx._onExitSync(self, function(exit)
      if exit._tag == 'Failure' and not Fx.Cause.isInterruptedOnly(exit.cause) then
        local tag = 'unknown'
        local e = Fx.Cause.failureOption(exit.cause)
        if #Fx.Cause.defects(exit.cause) > 0 then tag = 'defect'
        elseif type(e) == 'table' and type(e._tag) == 'string' then
          tag = Fx._declaredTags[e._tag] and e._tag or 'error'
        end
        local l = { error = tag }
        if labels then for k, v in pairs(labels) do l[k] = v end end
        counter:inc(1, l)
      end
    end)
  end

  -- Reading -------------------------------------------------------------------

  local function cloneLabels(l)
    local out = {}
    for k, v in pairs(l) do out[k] = v end
    return out
  end

  ---Every metric with its series:
  ---{ { name, kind, help, buckets?, series = { { labels, value } | { labels, counts, sum, count } } } }
  ---Histogram counts are per bucket (not cumulative); the last is above every bucket.
  function metrics.snapshot()
    local out = {}
    for _, m in ipairs(order) do
      local list = {}
      if m.collect then
        local ok, r = pcall(m.collect)
        if not ok then
          Fx._reportDefect(('metric %s collect'):format(m.name), r)
        elseif type(r) == 'number' then
          list[1] = { labels = {}, value = r }
        elseif type(r) == 'table' then
          for _, s in ipairs(r) do
            local v = s.value or s[2]
            if type(v) == 'number' then list[#list + 1] = { labels = copyLabels(s.labels or s[1]), value = v } end
          end
        end
      else
        local keys = {}
        for k in pairs(m.series) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
          local s = m.series[k]
          if m.kind == 'histogram' then
            list[#list + 1] = { labels = cloneLabels(s.labels), counts = { table.unpack(s.counts) }, sum = s.sum, count = s.count }
          else
            list[#list + 1] = { labels = cloneLabels(s.labels), value = s.value }
          end
        end
      end
      out[#out + 1] = { name = m.name, kind = m.kind, help = m.help, buckets = m.buckets, series = list }
    end
    return out
  end

  local function escapeValue(v)
    return (tostring(v):gsub('\\', '\\\\'):gsub('\n', '\\n'):gsub('"', '\\"'))
  end
  local function escapeHelp(v)
    return (tostring(v):gsub('\\', '\\\\'):gsub('\n', '\\n'))
  end

  local function num(v)
    if type(v) ~= 'number' then return 'NaN' end
    if v ~= v then return 'NaN' end
    if v == math.huge then return '+Inf' end
    if v == -math.huge then return '-Inf' end
    if math.type(v) == 'integer' or v == math.floor(v) and math.abs(v) < 2^53 then return ('%d'):format(v) end
    return ('%.17g'):format(v)
  end

  local function renderLabels(labels, extra, le)
    local keys = {}
    for k in pairs(labels) do keys[#keys + 1] = k end
    if extra then for k in pairs(extra) do if labels[k] == nil then keys[#keys + 1] = k end end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local v = labels[k]
      if v == nil then v = extra[k] end
      parts[#parts + 1] = ('%s="%s"'):format(k, escapeValue(v))
    end
    if le then parts[#parts + 1] = ('le="%s"'):format(le) end
    if #parts == 0 then return '' end
    return '{' .. table.concat(parts, ',') .. '}'
  end

  ---The Prometheus text format. extraLabels (e.g. { resource = 'bank' }) go
  ---on every series that does not set them itself.
  function metrics.prometheus(extraLabels, snapshot)
    local lines = {}
    for _, m in ipairs(snapshot or metrics.snapshot()) do
      if m.help ~= '' then lines[#lines + 1] = ('# HELP %s %s'):format(m.name, escapeHelp(m.help)) end
      lines[#lines + 1] = ('# TYPE %s %s'):format(m.name, m.kind)
      for _, s in ipairs(m.series) do
        if m.kind == 'histogram' then
          local cum = 0
          for i, b in ipairs(m.buckets) do
            cum = cum + s.counts[i]
            lines[#lines + 1] = ('%s_bucket%s %s'):format(m.name, renderLabels(s.labels, extraLabels, num(b)), num(cum))
          end
          lines[#lines + 1] = ('%s_bucket%s %s'):format(m.name, renderLabels(s.labels, extraLabels, '+Inf'), num(s.count))
          lines[#lines + 1] = ('%s_sum%s %s'):format(m.name, renderLabels(s.labels, extraLabels), num(s.sum))
          lines[#lines + 1] = ('%s_count%s %s'):format(m.name, renderLabels(s.labels, extraLabels), num(s.count))
        else
          lines[#lines + 1] = ('%s%s %s'):format(m.name, renderLabels(s.labels, extraLabels), num(s.value))
        end
      end
    end
    return table.concat(lines, '\n') .. '\n'
  end

  -- Built in: the runner and fibers of this resource.
  metrics.gauge('rivo_fx_fibers', {
    help = 'Root fibers alive in this resource',
    collect = function()
      local n = 0
      for _ in pairs(Fx._rootFibers) do n = n + 1 end
      return n
    end,
  })
  metrics.gauge('rivo_fx_timers', {
    help = 'Timers waiting in the fiber runner',
    collect = function()
      local p = P.current
      local st = p and p.stats and p.stats()
      return st and st.timers or 0
    end,
  })
end
