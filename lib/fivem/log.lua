-- Structured logging. Level from the convar `rivo_fx:logLevel`
-- (debug | info | warn | error | none), default info.
return function(Fx)
  local log = {}
  local LEVELS = { debug = 1, info = 2, warn = 3, error = 4, none = 5 }
  local COLORS = { debug = '^8', info = '^2', warn = '^3', error = '^1' }

  local function readLevel()
    local v = (GetConvar and GetConvar('rivo_fx:logLevel', 'info') or 'info'):lower()
    return LEVELS[v] and v or 'info'
  end

  local level = readLevel()
  local sink

  ---Set the minimum level (overrides the convar).
  function log.setLevel(l)
    l = tostring(l):lower()
    assert(LEVELS[l], 'unknown log level ' .. tostring(l))
    level = l
  end

  function log.getLevel() return level end

  ---Send records somewhere else: fn(level, message, fields). Pass nil to restore printing.
  function log.setSink(fn) sink = fn end

  local function fieldsToString(fields)
    if not fields then return '' end
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      local v = fields[k]
      local s = type(v) == 'table' and Fx.inspect(v) or tostring(v)
      if s:find('\n') then
        parts[#parts + 1] = '\n  ' .. tostring(k) .. ':\n    ' .. s:gsub('\n', '\n    ')
      else
        parts[#parts + 1] = tostring(k) .. '=' .. s
      end
    end
    return ' ' .. table.concat(parts, ' ')
  end

  local function write(l, msg, fields)
    -- errors reach the devtools whatever the level
    if l == 'error' then Fx._recordFailure(tostring(msg), fields) end
    if LEVELS[l] < LEVELS[level] then return end
    if sink then return sink(l, msg, fields) end
    print(('%s[%s]^7 %s%s'):format(COLORS[l], l:upper(), tostring(msg), fieldsToString(fields)))
  end

  for name in pairs(COLORS) do
    log[name] = function(msg, fields) write(name, msg, fields) end
  end

  -- Effect versions, annotated with the fiber id and the current span.
  local function effectLog(l)
    return function(msg, fields)
      return Fx.withFiber(function(fiber)
        local f = { fiber = fiber.id }
        local span = fiber.context[Fx.trace.CurrentSpan]
        if span then f.traceId, f.spanId = span.traceId, span.spanId end
        if fields then for k, v in pairs(fields) do f[k] = v end end
        write(l, msg, f)
        return Fx.unit
      end)
    end
  end
  Fx.logDebug = effectLog('debug')
  Fx.logInfo = effectLog('info')
  Fx.logWarn = effectLog('warn')
  Fx.logError = effectLog('error')

  return log
end
