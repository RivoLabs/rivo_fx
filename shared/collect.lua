-- Reads the telemetry of every resource on this side that uses Rivo FX
-- (lib/fivem/telemetry.lua), for server/hub.lua and the /fxdev devtools.
local known = {} -- resource name -> true

AddEventHandler('rivo_fx:telemetry:hello', function(res)
  if type(res) == 'string' then known[res] = true end
end)
TriggerEvent('rivo_fx:telemetry:who')

local C = {}
local SELF = GetCurrentResourceName()

---Started resources that use Rivo FX, sorted. opts.self = false leaves out
---rivo_fx itself (the devtools show the resources being built, not the tool).
function C.resources(opts)
  local skipSelf = opts and opts.self == false
  local list = {}
  for res in pairs(known) do
    if GetResourceState(res) ~= 'started' then
      known[res] = nil
    elseif not (skipSelf and res == SELF) then
      list[#list + 1] = res
    end
  end
  table.sort(list)
  return list
end

function C.ask(res, what, opts)
  local ok, v = pcall(function() return exports[res]:__rivo_fx_telemetry(what, opts) end)
  if ok and type(v) == 'table' then return v end
  return nil
end

local function sameList(a, b)
  a, b = a or {}, b or {}
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

---Every resource's metrics merged into one snapshot, each series labelled
---with its resource. A metric whose kind or buckets differ between
---resources keeps the first resource's definition; the others are skipped.
function C.mergedMetrics(opts)
  local families, order = {}, {}
  for _, res in ipairs(C.resources(opts)) do
    for _, m in ipairs(C.ask(res, 'metrics') or {}) do
      local f = families[m.name]
      if not f then
        f = { name = m.name, kind = m.kind, help = m.help or '', buckets = m.buckets, series = {} }
        families[m.name] = f
        order[#order + 1] = f
      end
      local sameBuckets = f.kind ~= 'histogram' or sameList(f.buckets, m.buckets)
      if f.kind == m.kind and sameBuckets then
        for _, s in ipairs(m.series or {}) do
          s.labels = s.labels or {}
          if s.labels.resource == nil then s.labels.resource = res end
          f.series[#f.series + 1] = s
        end
      end
    end
  end
  return order
end

---The most recent spans of every resource, newest first.
function C.recentSpans(limit)
  local all = {}
  for _, res in ipairs(C.resources()) do
    local r = C.ask(res, 'spans')
    for _, s in ipairs(r and r.items or {}) do all[#all + 1] = s end
  end
  table.sort(all, function(a, b) return (a.endTime or 0) > (b.endTime or 0) end)
  local out = {}
  for i = 1, math.min(limit, #all) do out[i] = all[i] end
  return out
end

-- Devtools views -------------------------------------------------------------

local MAX_SERIES = 2000

---Items (spans or failures) newer than the cursor, per resource. cursor is
---the caller's table { [res] = { epoch, after } }; it moves forward.
local OTHERS = { self = false }

local function newer(what, cursor)
  local out = {}
  for _, res in ipairs(C.resources(OTHERS)) do
    local r = C.ask(res, what, cursor[res])
    if r and type(r.items) == 'table' then
      local last = cursor[res] and cursor[res].epoch == r.epoch and cursor[res].after or 0
      for _, item in ipairs(r.items) do
        out[#out + 1] = item
        if math.type(item.seq) == 'integer' and item.seq > last then last = item.seq end
      end
      cursor[res] = { epoch = r.epoch, after = last }
    end
  end
  return out
end

---The data behind one devtools view. cursors: the caller's table, kept
---between calls, so spans and failures are only sent once.
function C.view(view, cursors)
  if view == 'overview' then
    local out = {}
    for _, res in ipairs(C.resources(OTHERS)) do out[#out + 1] = C.ask(res, 'summary') end
    return out
  elseif view == 'fibers' then
    local out = {}
    for _, res in ipairs(C.resources(OTHERS)) do
      local r = C.ask(res, 'fibers', { limit = 200 })
      if r then
        r.resource = res
        out[#out + 1] = r
      end
    end
    return out
  elseif view == 'spans' or view == 'failures' then
    cursors[view] = cursors[view] or {}
    return newer(view, cursors[view])
  elseif view == 'metrics' then
    local families, total = C.mergedMetrics(OTHERS), 0
    for _, f in ipairs(families) do
      local keep = math.max(0, math.min(#f.series, MAX_SERIES - total))
      if keep < #f.series then
        f.dropped = #f.series - keep
        for i = #f.series, keep + 1, -1 do f.series[i] = nil end
      end
      total = total + keep
    end
    return families
  end
  return nil
end

RivoFxCollect = C
